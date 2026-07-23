defmodule YouWeb.ConsoleLive do
  @moduledoc """
  Operator console — the admin surface at `/console`.

  A single LiveView shell (sidebar + topbar + section views) in the same visual
  language as Sockeet's console: dense, mono-accented cards and tables, a live
  connection indicator, and `?view=` navigation. Every section is wired to the
  real domain (`You.Admin`, `You.Organizations`, `You.Settings`,
  `You.Audit.Streamer`) — no fabricated data.
  """
  use YouWeb, :live_view

  alias You.{Admin, Organizations, Accounts, Settings}
  alias You.Audit.Streamer

  @nav [
    %{id: "overview", label: "Overview", icon: "lucide-layout-dashboard"},
    %{id: "users", label: "Users", icon: "lucide-users"},
    %{id: "apps", label: "Apps", icon: "lucide-boxes"},
    %{id: "orgs", label: "Organizations", icon: "lucide-building-2"},
    %{id: "audit", label: "Audit Log", icon: "lucide-scroll-text"},
    %{id: "settings", label: "Settings", icon: "lucide-settings"}
  ]

  @roles ~w(owner admin member)

  @settings_fields [
    %{key: :session_expiry_hours, label: "Session expiry (hours)"},
    %{key: :jwt_expiry_hours, label: "JWT expiry (hours)"},
    %{key: :code_expiry_minutes, label: "Auth code expiry (minutes)"},
    %{key: :magic_link_expiry_minutes, label: "Magic link expiry (minutes)"},
    %{key: :erlang_node_name, label: "Erlang node name"},
    %{key: :epmd_port, label: "EPMD port"},
    %{key: :erlang_cookie, label: "Erlang cookie"},
    %{key: :scim_bearer_token, label: "SCIM bearer token"},
    %{key: :audit_webhook_url, label: "Audit webhook URL"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, self(), :refresh)

    {:ok,
     socket
     |> assign(
       page_title: "Console",
       nav: @nav,
       view: "overview",
       node_name: Node.self(),
       roles: @roles,
       new_secret: nil,
       secret_app: nil,
       selected_org: nil,
       members: [],
       base_url: YouWeb.Endpoint.url(),
       oidc_providers: Application.get_env(:you, :oidc_providers, %{}) |> Map.keys() |> Enum.sort(),
       saved: false
     )
     |> load_data()
     |> load_settings()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    view = params["view"] || "overview"
    view = if Enum.any?(@nav, &(&1.id == view)), do: view, else: "overview"
    {:noreply, assign(socket, view: view, saved: false)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_data(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── users ─────────────────────────────────────────────────────
  @impl true
  def handle_event("promote", %{"id" => id}, socket) do
    Admin.get_user!(id) |> Admin.promote_admin()
    {:noreply, socket |> load_data() |> put_flash(:info, "User promoted to admin.")}
  end

  def handle_event("demote", %{"id" => id}, socket) do
    Admin.get_user!(id) |> Admin.demote_admin()
    {:noreply, socket |> load_data() |> put_flash(:info, "Admin rights revoked.")}
  end

  # ── apps ──────────────────────────────────────────────────────
  def handle_event("create_app", params, socket) do
    case Admin.create_app(Map.take(params, ["name", "slug", "callback_url"])) do
      {:ok, app, secret} ->
        {:noreply, socket |> load_data() |> assign(new_secret: secret, secret_app: app)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create app: #{errors(changeset)}")}
    end
  end

  def handle_event("rotate_secret", %{"id" => id}, socket) do
    case id |> Admin.get_app!() |> Admin.rotate_app_secret() do
      {:ok, app, secret} -> {:noreply, assign(socket, new_secret: secret, secret_app: app)}
      {:error, cs} -> {:noreply, put_flash(socket, :error, "Could not rotate: #{errors(cs)}")}
    end
  end

  def handle_event("delete_app", %{"id" => id}, socket) do
    id |> Admin.get_app!() |> Admin.delete_app()
    {:noreply, socket |> load_data() |> put_flash(:info, "App deleted.")}
  end

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, new_secret: nil, secret_app: nil)}

  # ── orgs ──────────────────────────────────────────────────────
  def handle_event("create_org", params, socket) do
    case Organizations.create_organization(Map.take(params, ["name", "slug"])) do
      {:ok, _org} -> {:noreply, socket |> load_data() |> put_flash(:info, "Organization created.")}
      {:error, cs} -> {:noreply, put_flash(socket, :error, "Could not create org: #{errors(cs)}")}
    end
  end

  def handle_event("select_org", %{"id" => id}, socket), do: {:noreply, select_org(socket, id)}

  def handle_event("add_member", %{"email" => email, "role" => role}, socket) do
    org = socket.assigns.selected_org

    case Accounts.get_user_by_email(email) do
      nil ->
        {:noreply, put_flash(socket, :error, "No user with email #{email}.")}

      user ->
        case Organizations.add_member(org, user, role) do
          {:ok, _} -> {:noreply, socket |> select_org(org.id) |> put_flash(:info, "Member added.")}
          {:error, cs} -> {:noreply, put_flash(socket, :error, "Could not add: #{errors(cs)}")}
        end
    end
  end

  def handle_event("update_role", %{"user_id" => uid, "role" => role}, socket) do
    org = socket.assigns.selected_org
    Organizations.update_member_role(org, Admin.get_user!(uid), role)
    {:noreply, select_org(socket, org.id)}
  end

  def handle_event("remove_member", %{"user_id" => uid}, socket) do
    org = socket.assigns.selected_org
    Organizations.remove_member(org, Admin.get_user!(uid))
    {:noreply, socket |> select_org(org.id) |> put_flash(:info, "Member removed.")}
  end

  # ── settings ──────────────────────────────────────────────────
  def handle_event("save_settings", params, socket) do
    Enum.each(@settings_fields, fn %{key: key} ->
      raw = params[Atom.to_string(key)]
      if is_binary(raw), do: Settings.set(key, parse_value(raw))
    end)

    You.Accounts.CookieSync.apply_cookie()
    You.Audit.Streamer.reload()
    {:noreply, socket |> load_settings() |> assign(saved: true)}
  end

  # ── data loading ──────────────────────────────────────────────
  defp load_data(socket) do
    org = socket.assigns[:selected_org]

    socket
    |> assign(
      users: Admin.list_users_with_stats(),
      apps: Admin.list_apps(),
      orgs: Organizations.list_organizations_with_counts(),
      events: Streamer.recent()
    )
    |> assign(members: if(org, do: Organizations.list_members(org), else: []))
  end

  defp load_settings(socket),
    do: assign(socket, settings: Settings.all())

  defp select_org(socket, id) do
    case Organizations.get_organization(id) do
      nil -> assign(socket, selected_org: nil, members: [])
      org -> assign(socket, selected_org: org, members: Organizations.list_members(org))
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {f, msgs} -> "#{f} #{Enum.join(msgs, ", ")}" end)
  end

  defp parse_value(raw) do
    if raw =~ ~r/^\d+$/, do: String.to_integer(raw), else: raw
  end

  defp nav_label(view), do: Enum.find_value(@nav, "", &if(&1.id == view, do: &1.label))

  # ── shell ─────────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-background text-foreground">
      <aside class="flex w-56 shrink-0 flex-col border-r border-sidebar-border bg-sidebar">
        <div class="flex h-12 items-center gap-2 border-b border-sidebar-border px-4">
          <span class="grid h-6 w-6 place-items-center rounded bg-primary text-primary-foreground">
            <span class="text-[10px] font-bold">Y</span>
          </span>
          <span class="font-mono text-sm font-semibold">
            you <span class="text-primary">//</span>
          </span>
        </div>

        <nav class="flex-1 space-y-0.5 px-2 pt-2">
          <.link
            :for={n <- @nav}
            patch={~p"/console?view=#{n.id}"}
            class={[
              "flex h-8 w-full items-center gap-2.5 rounded-md px-2.5 text-sm transition-colors",
              if(@view == n.id,
                do: "bg-sidebar-accent text-sidebar-accent-foreground",
                else: "text-sidebar-foreground hover:bg-sidebar-muted hover:text-foreground"
              )
            ]}
          >
            <span class={[n.icon, "size-4 block shrink-0"]} /> {n.label}
          </.link>
        </nav>

        <div class="space-y-1 border-t border-sidebar-border px-2 py-2">
          <.link
            navigate={~p"/users/settings"}
            class="flex h-8 items-center gap-2.5 rounded-md px-2.5 text-sm text-sidebar-foreground transition-colors hover:bg-sidebar-muted hover:text-foreground"
          >
            <span class="lucide-user size-4 block shrink-0" /> My account
          </.link>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="flex h-8 items-center gap-2.5 rounded-md px-2.5 text-sm text-sidebar-foreground transition-colors hover:bg-sidebar-muted hover:text-foreground"
          >
            <span class="lucide-log-out size-4 block shrink-0" /> Sign out
          </.link>
        </div>

        <div class="border-t border-sidebar-border px-4 py-2.5 font-mono text-[11px] text-muted-foreground">
          Identity &amp; Access
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="flex h-12 shrink-0 items-center gap-3 border-b border-border px-4">
          <div class="text-sm font-medium">{nav_label(@view)}</div>
          <div class="ml-auto flex items-center gap-3">
            <span class="hidden items-center gap-1.5 font-mono text-xs text-muted-foreground sm:flex">
              <span class="h-1.5 w-1.5 animate-pulse-live rounded-full bg-signal-live" />
              connected · {@node_name}
            </span>
            <.theme_toggle id="console-theme" />
          </div>
        </header>

        <main class="flex-1 overflow-y-auto p-6">
          <%= case @view do %>
            <% "overview" -> %>
              <.overview users={@users} apps={@apps} orgs={@orgs} events={@events} />
            <% "users" -> %>
              <.users_view users={@users} current_scope={@current_scope} />
            <% "apps" -> %>
              <.apps_view apps={@apps} new_secret={@new_secret} secret_app={@secret_app} />
            <% "orgs" -> %>
              <.orgs_view orgs={@orgs} selected={@selected_org} members={@members} roles={@roles} />
            <% "audit" -> %>
              <.audit_view events={@events} />
            <% "settings" -> %>
              <.settings_view
                settings={@settings}
                base_url={@base_url}
                oidc_providers={@oidc_providers}
                saved={@saved}
              />
          <% end %>
        </main>
      </div>
    </div>

    <Layouts.flash_group flash={@flash} />
    """
  end

  # ── section: overview ─────────────────────────────────────────
  attr :users, :list, required: true
  attr :apps, :list, required: true
  attr :orgs, :list, required: true
  attr :events, :list, required: true

  defp overview(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <.metric_card label="Users" value={to_string(length(@users))} />
        <.metric_card label="Admins" value={to_string(Enum.count(@users, & &1.user.is_admin))} />
        <.metric_card label="Apps" value={to_string(length(@apps))} />
        <.metric_card label="Organizations" value={to_string(length(@orgs))} />
      </div>

      <div class="rounded-lg border border-border bg-card p-4">
        <div class="mb-3 flex items-center gap-2 text-sm font-medium">
          <span class="lucide-activity size-4 block text-primary" /> Recent activity
        </div>
        <ul class="space-y-2 text-xs">
          <li :for={e <- Enum.take(@events, 8)} class="flex items-center gap-3">
            <span class="font-mono text-foreground/90">{e.event}</span>
            <span class="truncate font-mono text-muted-foreground/70">{brief(e.metadata)}</span>
            <span class="ml-auto shrink-0 font-mono text-muted-foreground/70">{clock(e.at)}</span>
          </li>
          <li :if={@events == []} class="text-muted-foreground">No activity recorded yet.</li>
        </ul>
      </div>
    </div>
    """
  end

  # ── section: users ────────────────────────────────────────────
  attr :users, :list, required: true
  attr :current_scope, :map, required: true

  defp users_view(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="font-mono text-xs text-muted-foreground">
        <span class="text-foreground">{length(@users)} users</span>
        · {Enum.count(@users, & &1.user.is_admin)} admins
      </div>

      <.data_table cols={~w(Email Status Role Passkeys Federated) ++ [""]} empty={@users == []}>
        <tr
          :for={row <- @users}
          class="border-b border-border/60 transition-colors last:border-0 hover:bg-muted/40"
        >
          <td class="px-3 py-2 font-mono text-xs text-foreground/90">{row.user.email}</td>
          <td class="px-3 py-2">
            <.status_badge status={if row.user.confirmed_at, do: "running", else: "idle"} />
          </td>
          <td class="px-3 py-2 font-mono text-xs">
            <span class={if row.user.is_admin, do: "text-primary", else: "text-muted-foreground"}>
              {if row.user.is_admin, do: "admin", else: "user"}
            </span>
          </td>
          <td class="px-3 py-2 text-right font-mono text-xs tabular-nums text-muted-foreground">
            {row.passkeys}
          </td>
          <td class="px-3 py-2 text-right font-mono text-xs tabular-nums text-muted-foreground">
            {row.identities}
          </td>
          <td class="px-3 py-2 text-right">
            <button
              :if={!row.user.is_admin}
              type="button"
              phx-click="promote"
              phx-value-id={row.user.id}
              class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-primary hover:text-primary-foreground"
            >
              Make admin
            </button>
            <button
              :if={row.user.is_admin && row.user.id != @current_scope.user.id}
              type="button"
              phx-click="demote"
              phx-value-id={row.user.id}
              class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-destructive hover:text-destructive-foreground"
            >
              Revoke
            </button>
          </td>
        </tr>
      </.data_table>
    </div>
    """
  end

  # ── section: apps ─────────────────────────────────────────────
  attr :apps, :list, required: true
  attr :new_secret, :string, default: nil
  attr :secret_app, :map, default: nil

  defp apps_view(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <span class="font-mono text-xs text-muted-foreground">{length(@apps)} apps</span>
        <.dialog id="new-app">
          <:trigger>
            <.button size="sm"><span class="lucide-plus size-4 block" /> New app</.button>
          </:trigger>
          <:title>Register app</:title>
          <:description>A client secret is generated and shown once on creation.</:description>
          <form phx-submit="create_app" class="space-y-4">
            <.input type="text" name="name" label="Name" value="" required />
            <.input type="text" name="slug" label="Slug (client_id)" value="" required />
            <.input type="url" name="callback_url" label="Callback URL" value="" required />
            <div class="flex justify-end">
              <.button type="submit">Create</.button>
            </div>
          </form>
        </.dialog>
      </div>

      <.data_table cols={~w(Name Client-ID Callback Secret) ++ [""]} empty={@apps == []}>
        <tr
          :for={app <- @apps}
          class="border-b border-border/60 transition-colors last:border-0 hover:bg-muted/40"
        >
          <td class="px-3 py-2 text-xs">{app.name}</td>
          <td class="px-3 py-2 font-mono text-xs text-foreground/90">{app.slug}</td>
          <td class="px-3 py-2 font-mono text-xs text-muted-foreground">{app.callback_url}</td>
          <td class="px-3 py-2">
            <.status_badge status={if app.client_secret_hash, do: "running", else: "idle"} />
          </td>
          <td class="px-3 py-2 text-right whitespace-nowrap">
            <button
              type="button"
              phx-click="rotate_secret"
              phx-value-id={app.id}
              class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
            >
              Rotate
            </button>
            <button
              type="button"
              phx-click="delete_app"
              phx-value-id={app.id}
              data-confirm={"Delete app “#{app.name}”? This cannot be undone."}
              class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-destructive hover:text-destructive-foreground"
            >
              Delete
            </button>
          </td>
        </tr>
      </.data_table>

      <.dialog id="app-secret" open={@new_secret != nil} on_close="dismiss_secret">
        <:title>Client secret</:title>
        <:description>Copy this now — it is hashed at rest and never shown again.</:description>
        <div :if={@new_secret} class="space-y-3">
          <div class="rounded-md border border-border bg-background px-3 py-2 font-mono text-xs break-all text-primary">
            {@new_secret}
          </div>
          <div class="flex items-center justify-between">
            <span :if={@secret_app} class="font-mono text-xs text-muted-foreground">
              client_id: {@secret_app.slug}
            </span>
            <.copy_button id="copy-secret" value={@new_secret} label="Copy secret" />
          </div>
        </div>
        <:footer>
          <.button variant="outline" phx-click="dismiss_secret">Done</.button>
        </:footer>
      </.dialog>
    </div>
    """
  end

  # ── section: orgs ─────────────────────────────────────────────
  attr :orgs, :list, required: true
  attr :selected, :map, default: nil
  attr :members, :list, required: true
  attr :roles, :list, required: true

  defp orgs_view(assigns) do
    ~H"""
    <div class="grid gap-4 lg:grid-cols-[16rem_1fr]">
      <div class="space-y-2">
        <div class="flex items-center justify-between">
          <span class="font-mono text-xs text-muted-foreground">{length(@orgs)} orgs</span>
          <.dialog id="new-org">
            <:trigger>
              <.button size="xs" variant="outline">
                <span class="lucide-plus size-3.5 block" /> New
              </.button>
            </:trigger>
            <:title>Create organization</:title>
            <form phx-submit="create_org" class="space-y-4">
              <.input type="text" name="name" label="Name" value="" required />
              <.input type="text" name="slug" label="Slug" value="" required />
              <div class="flex justify-end">
                <.button type="submit">Create</.button>
              </div>
            </form>
          </.dialog>
        </div>

        <div class="overflow-hidden rounded-lg border border-border">
          <button
            :for={{org, count} <- @orgs}
            type="button"
            phx-click="select_org"
            phx-value-id={org.id}
            class={[
              "flex w-full items-center justify-between border-b border-border/60 px-3 py-2 text-left text-sm transition-colors last:border-0",
              if(@selected && @selected.id == org.id,
                do: "bg-muted/60 text-foreground",
                else: "text-muted-foreground hover:bg-muted/40 hover:text-foreground"
              )
            ]}
          >
            <span class="truncate">{org.name}</span>
            <span class="font-mono text-xs text-muted-foreground/70">{count}</span>
          </button>
          <div :if={@orgs == []} class="px-3 py-8 text-center text-xs text-muted-foreground">
            No organizations.
          </div>
        </div>
      </div>

      <div :if={@selected} class="space-y-4">
        <div>
          <div class="text-sm font-medium">{@selected.name}</div>
          <div class="font-mono text-xs text-muted-foreground">{@selected.slug}</div>
        </div>

        <form phx-submit="add_member" class="flex items-end gap-2">
          <div class="flex-1">
            <.input type="email" name="email" label="Add member by email" value="" required />
          </div>
          <.input
            type="select"
            name="role"
            label="Role"
            value="member"
            options={Enum.map(@roles, &{String.capitalize(&1), &1})}
          />
          <.button type="submit">Add</.button>
        </form>

        <.data_table cols={~w(Email Role) ++ [""]} empty={@members == []}>
          <tr
            :for={{user, role} <- @members}
            class="border-b border-border/60 last:border-0 hover:bg-muted/40"
          >
            <td class="px-3 py-2 font-mono text-xs text-foreground/90">{user.email}</td>
            <td class="px-3 py-2">
              <form phx-change="update_role" class="inline-flex">
                <input type="hidden" name="user_id" value={user.id} />
                <select
                  name="role"
                  class="h-7 rounded-md border border-input bg-background px-2 font-mono text-xs"
                >
                  <option :for={r <- @roles} value={r} selected={r == role}>
                    {String.capitalize(r)}
                  </option>
                </select>
              </form>
            </td>
            <td class="px-3 py-2 text-right">
              <button
                type="button"
                phx-click="remove_member"
                phx-value-user_id={user.id}
                class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-destructive hover:text-destructive-foreground"
              >
                Remove
              </button>
            </td>
          </tr>
        </.data_table>
      </div>

      <div
        :if={@selected == nil}
        class="grid place-items-center rounded-lg border border-dashed border-border text-sm text-muted-foreground"
      >
        Select an organization to manage members.
      </div>
    </div>
    """
  end

  # ── section: audit ────────────────────────────────────────────
  attr :events, :list, required: true

  defp audit_view(assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="font-mono text-xs text-muted-foreground">
        in-memory · newest first · configure a webhook under Settings for durable retention
      </p>
      <.data_table cols={~w(Event Details At)} empty={@events == []}>
        <tr :for={e <- @events} class="border-b border-border/60 last:border-0 hover:bg-muted/40">
          <td class="px-3 py-2 font-mono text-xs text-foreground/90">{e.event}</td>
          <td class="px-3 py-2 font-mono text-xs break-all text-muted-foreground">
            {brief(e.metadata)}
          </td>
          <td class="px-3 py-2 text-right font-mono text-xs tabular-nums text-muted-foreground">
            {e.at}
          </td>
        </tr>
      </.data_table>
    </div>
    """
  end

  # ── section: settings ─────────────────────────────────────────
  attr :settings, :map, required: true
  attr :base_url, :string, required: true
  attr :oidc_providers, :list, required: true
  attr :saved, :boolean, required: true

  defp settings_view(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-4">
      <div
        :if={@saved}
        class="flex items-center gap-2 rounded-lg border border-signal-ok/40 bg-signal-ok/10 p-3 text-sm"
      >
        <span class="lucide-check size-4 block text-signal-ok" /> Settings saved.
      </div>

      <form phx-submit="save_settings" class="space-y-4">
        <.settings_group title="Session & tokens">
          <.setting_field name="session_expiry_hours" label="Session expiry (hours)" value={@settings[:session_expiry_hours]} />
          <.setting_field name="jwt_expiry_hours" label="JWT expiry (hours)" value={@settings[:jwt_expiry_hours]} />
          <.setting_field name="code_expiry_minutes" label="Auth code expiry (minutes)" value={@settings[:code_expiry_minutes]} />
          <.setting_field name="magic_link_expiry_minutes" label="Magic link expiry (minutes)" value={@settings[:magic_link_expiry_minutes]} />
        </.settings_group>

        <.settings_group title="Erlang distribution">
          <.setting_field name="erlang_node_name" label="Node name" value={@settings[:erlang_node_name]} />
          <.setting_field name="epmd_port" label="EPMD port" value={@settings[:epmd_port]} />
          <.setting_field name="erlang_cookie" label="Cookie" value={@settings[:erlang_cookie]} type="password" />
        </.settings_group>

        <.settings_group title="Provisioning & audit">
          <.setting_field name="scim_bearer_token" label="SCIM bearer token" value={@settings[:scim_bearer_token]} type="password" />
          <.setting_field name="audit_webhook_url" label="Audit webhook URL" value={@settings[:audit_webhook_url]} />
          <p class="pt-1 font-mono text-[11px] text-muted-foreground">
            SCIM base: {@base_url}/scim/v2 · blank tokens disable the feature
          </p>
        </.settings_group>

        <.button type="submit">Save settings</.button>
      </form>

      <div class="rounded-lg border border-border bg-card p-5">
        <div class="flex items-center gap-2 text-sm font-medium">
          <span class="lucide-globe size-4 block text-primary" /> OIDC &amp; federation
        </div>
        <dl class="mt-3 space-y-2 text-xs">
          <.kv k="Discovery" v={"#{@base_url}/.well-known/openid-configuration"} />
          <.kv k="JWKS" v={"#{@base_url}/.well-known/jwks.json"} />
          <.kv k="Token" v={"#{@base_url}/oauth/token"} />
          <.kv k="PKCE" v="S256" />
        </dl>
        <div class="mt-3">
          <div class="mb-1.5 text-xs font-medium">Upstream providers</div>
          <span :if={@oidc_providers == []} class="font-mono text-[11px] text-muted-foreground">
            none configured
          </span>
          <div :if={@oidc_providers != []} class="flex flex-wrap gap-1.5">
            <span
              :for={p <- @oidc_providers}
              class="rounded border border-border bg-muted px-2 py-0.5 font-mono text-[11px]"
            >
              {p}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── small shared pieces ───────────────────────────────────────
  attr :cols, :list, required: true
  attr :empty, :boolean, default: false
  slot :inner_block, required: true

  defp data_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-lg border border-border">
      <table class="w-full text-sm">
        <thead>
          <tr class="border-b border-border bg-muted/40 text-left font-mono text-xs uppercase tracking-wide text-muted-foreground">
            <th
              :for={{c, i} <- Enum.with_index(@cols)}
              class={["px-3 py-2 font-medium", i > 0 && c == "" && "text-right"]}
            >
              {c}
            </th>
          </tr>
        </thead>
        <tbody>
          {render_slot(@inner_block)}
          <tr :if={@empty}>
            <td colspan={length(@cols)} class="px-3 py-8 text-center text-sm text-muted-foreground">
              Nothing here yet.
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp settings_group(assigns) do
    ~H"""
    <div class="rounded-lg border border-border bg-card p-5">
      <div class="mb-3 text-sm font-medium">{@title}</div>
      <div class="space-y-3">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :type, :string, default: "text"

  defp setting_field(assigns) do
    ~H"""
    <label class="flex items-center justify-between gap-4 text-sm">
      <span class="text-muted-foreground">{@label}</span>
      <.base_input type={@type} name={@name} value={@value} class="h-8 max-w-[16rem] font-mono text-xs" />
    </label>
    """
  end

  attr :k, :string, required: true
  attr :v, :string, required: true

  defp kv(assigns) do
    ~H"""
    <div class="flex justify-between gap-4 border-b border-border/60 pb-1.5 last:border-0">
      <dt class="text-muted-foreground">{@k}</dt>
      <dd class="font-mono text-right break-all text-primary">{@v}</dd>
    </div>
    """
  end

  attr :id, :string, required: true

  defp theme_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      phx-hook="ThemeToggle"
      aria-label="Toggle theme"
      class="grid size-8 place-items-center rounded-md border border-border hover:bg-muted/50"
    >
      <.icon name="moon" class="size-4 text-brand-azure block dark:hidden" />
      <.icon name="sun" class="size-4 text-signal-warn hidden dark:block" />
    </button>
    """
  end

  # ── formatting ────────────────────────────────────────────────
  defp brief(metadata) when is_map(metadata) do
    metadata
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end

  defp brief(_), do: ""

  defp clock(at) when is_binary(at) do
    case String.split(at, "T") do
      [_, time | _] -> String.slice(time, 0, 8)
      _ -> at
    end
  end

  defp clock(_), do: ""
end
