defmodule YouWeb.AppLive.Show do
  @moduledoc """
  Per-app console page at `/console/apps/:slug`.

  Splits what used to be a single edit dialog into tabs: identity and URLs,
  login branding, the app's `allowed_roles`, who holds them, and the client
  credentials. The active tab lives in `?tab=` so a tab is linkable.
  """
  use YouWeb, :live_view

  import YouWeb.Components.ConsoleChrome

  alias You.{Admin, Roles}

  @tabs [
    {"overview", "Overview"},
    {"login", "Login"},
    {"roles", "Roles"},
    {"members", "Members"},
    {"credentials", "Credentials"}
  ]

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    {:ok,
     socket
     |> assign(
       nav: nav(),
       node_name: Node.self(),
       tabs: @tabs,
       tab: "overview",
       new_secret: nil,
       selected: MapSet.new(),
       preview_theme: "light"
     )
     |> assign_app(Admin.get_app_by_slug!(slug))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "overview"
    tab = if List.keymember?(@tabs, tab, 0), do: tab, else: "overview"
    {:noreply, assign(socket, tab: tab)}
  end

  # ── overview ──────────────────────────────────────────────────
  @impl true
  def handle_event("update_app", params, socket) do
    socket.assigns.app
    |> Admin.update_app(Map.take(params, ["name", "callback_url", "launch_url", "first_party"]))
    |> reload(socket, "App updated.")
  end

  # ── login branding ────────────────────────────────────────────
  def handle_event("preview_branding", params, socket) do
    {:noreply,
     assign(socket,
       draft: %{
         logo_url: safe_logo_url(params["logo_url"]),
         brand_color: safe_brand_color(params["brand_color"]),
         headline: safe_copy(params["headline"]),
         subtitle: safe_copy(params["subtitle"])
       }
     )}
  end

  def handle_event("update_branding", params, socket) do
    socket.assigns.app
    |> Admin.update_app(Map.take(params, ["logo_url", "brand_color", "headline", "subtitle"]))
    |> reload(socket, "Branding updated.")
  end

  def handle_event("toggle_preview_theme", _params, socket) do
    theme = if socket.assigns.preview_theme == "dark", do: "light", else: "dark"
    {:noreply, assign(socket, preview_theme: theme)}
  end

  # ── consent screen ────────────────────────────────────────────
  def handle_event("update_consent_urls", params, socket) do
    socket.assigns.app
    |> Admin.update_app(Map.take(params, ["tos_url", "privacy_url"]))
    |> reload(socket, "Consent screen updated.")
  end

  # ── roles ─────────────────────────────────────────────────────
  def handle_event("add_role", %{"role" => role}, socket) do
    app = socket.assigns.app

    app
    |> Admin.update_allowed_roles(allowed_roles(app) ++ [role])
    |> reload(socket, "Role added.")
  end

  def handle_event("remove_role", %{"role" => role}, socket) do
    app = socket.assigns.app

    app
    |> Admin.update_allowed_roles(allowed_roles(app) -- [role])
    |> reload(socket, "Role removed.")
  end

  def handle_event("set_default_role", %{"default_role" => role}, socket) do
    socket.assigns.app
    |> Admin.set_default_role(role)
    |> reload(socket, "Default role updated.")
  end

  # ── members ───────────────────────────────────────────────────
  def handle_event("set_member_role", %{"user_id" => user_id} = params, socket) do
    app = socket.assigns.app
    user = Admin.get_user!(user_id)
    role = params["value"] || params["role"]

    case Roles.set_role(app, user, role) do
      {:ok, _} ->
        {:noreply, assign_app(socket, app)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Role is not allowed for this app.")}
    end
  end

  def handle_event("toggle_member", %{"user_id" => user_id}, socket) do
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, user_id),
        do: MapSet.delete(selected, user_id),
        else: MapSet.put(selected, user_id)

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("toggle_all_members", _params, socket) do
    all = MapSet.new(socket.assigns.members, fn {user, _} -> to_string(user.id) end)

    selected =
      if MapSet.equal?(socket.assigns.selected, all), do: MapSet.new(), else: all

    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("bulk_set_role", params, socket) do
    app = socket.assigns.app
    user_ids = MapSet.to_list(socket.assigns.selected)

    case Roles.set_roles(app, user_ids, params["role"] || params["value"]) do
      {:ok, count} ->
        {:noreply,
         socket
         |> assign_app(app)
         |> assign(selected: MapSet.new())
         |> put_flash(:info, "Updated #{count} #{if count == 1, do: "user", else: "users"}.")}

      {:error, :invalid_role} ->
        {:noreply, put_flash(socket, :error, "Role is not allowed for this app.")}

      {:error, :invalid_user} ->
        {:noreply,
         put_flash(socket, :error, "That selection is no longer valid. Reload the page.")}
    end
  end

  # ── credentials ───────────────────────────────────────────────
  def handle_event("rotate_secret", _params, socket) do
    case Admin.rotate_app_secret(socket.assigns.app) do
      {:ok, app, secret} ->
        {:noreply, socket |> assign_app(app) |> assign(new_secret: secret)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not rotate: #{error_summary(changeset)}")}
    end
  end

  def handle_event("dismiss_secret", _params, socket) do
    {:noreply, assign(socket, new_secret: nil)}
  end

  # ── helpers ───────────────────────────────────────────────────
  defp assign_app(socket, %Admin.App{} = app) do
    assign(socket,
      app: app,
      page_title: app.name,
      draft: %{
        logo_url: app.logo_url,
        brand_color: app.brand_color,
        headline: app.headline,
        subtitle: app.subtitle
      },
      members: Roles.list_for_app(app),
      role_counts: Roles.count_by_role(app)
    )
  end

  defp reload({:ok, app}, socket, message) do
    {:noreply, socket |> assign_app(app) |> put_flash(:info, message)}
  end

  defp reload({:error, {:roles_in_use, roles}}, socket, _message) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Still assigned to users: #{Enum.join(roles, ", ")}. Move them off it first."
     )}
  end

  defp reload({:error, changeset}, socket, _message) do
    {:noreply, put_flash(socket, :error, error_summary(changeset))}
  end

  defp allowed_roles(app), do: app.allowed_roles || ["user", "admin"]

  # ── render ────────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    ~H"""
    <.console_shell nav={@nav} active="apps" title="Apps" node_name={@node_name}>
      <div class="space-y-5">
        <div>
          <.link
            navigate={~p"/console?view=apps"}
            class="font-mono text-xs text-muted-foreground transition-colors hover:text-foreground"
          >
            ← Apps
          </.link>
          <h1 class="mt-1 text-lg font-medium">{@app.name}</h1>
          <p class="font-mono text-xs text-muted-foreground">{@app.slug}</p>
        </div>

        <.tab_strip tabs={@tabs} active={@tab} path={~p"/console/apps/#{@app.slug}"} />

        <%= case @tab do %>
          <% "overview" -> %>
            <.overview_tab app={@app} />
          <% "login" -> %>
            <.login_tab app={@app} draft={@draft} preview_theme={@preview_theme} />
          <% "roles" -> %>
            <.roles_tab
              app={@app}
              roles={allowed_roles(@app)}
              counts={@role_counts}
              default_role={@app.default_role || "user"}
            />
          <% "members" -> %>
            <.members_tab
              app={@app}
              members={@members}
              roles={allowed_roles(@app)}
              selected={@selected}
            />
          <% "credentials" -> %>
            <.credentials_tab app={@app} new_secret={@new_secret} />
        <% end %>
      </div>

      <Layouts.flash_group flash={@flash} />
    </.console_shell>
    """
  end

  attr :app, :map, required: true

  defp overview_tab(assigns) do
    ~H"""
    <.panel title="Identity and URLs" description="How the app is registered with You.">
      <form id="app-overview-form" phx-submit="update_app" class="max-w-xl space-y-4">
        <.input type="text" name="name" label="Name" value={@app.name} required />
        <.input
          type="url"
          name="callback_url"
          label="Callback URL"
          value={@app.callback_url}
          required
        />
        <.input type="url" name="launch_url" label="Launch URL (optional)" value={@app.launch_url} />
        <.input
          type="checkbox"
          name="first_party"
          label="First-party app"
          value="true"
          checked={@app.first_party}
        />
        <div class="flex justify-end">
          <.button type="submit">Save</.button>
        </div>
      </form>
    </.panel>
    """
  end

  attr :app, :map, required: true
  attr :draft, :map, required: true
  attr :preview_theme, :string, required: true

  defp login_tab(assigns) do
    ~H"""
    <div class="grid gap-5 lg:grid-cols-2">
      <div class="space-y-5">
        <.panel
          title="Branding"
          description="Shown on You's login page when users arrive from this app."
        >
          <form
            id="app-branding-form"
            phx-change="preview_branding"
            phx-submit="update_branding"
            class="space-y-4"
          >
            <.input type="url" name="logo_url" label="Logo URL (optional)" value={@draft.logo_url} />
            <.input
              type="text"
              name="brand_color"
              label="Brand color (optional)"
              value={@draft.brand_color}
              placeholder="#7c3aed"
            />
            <.input
              type="text"
              name="headline"
              label="Headline (optional)"
              value={@draft.headline}
              placeholder={"Sign in to continue to #{@app.name}"}
            />
            <.input
              type="text"
              name="subtitle"
              label="Subtitle (optional)"
              value={@draft.subtitle}
              placeholder="secured by You"
            />
            <div class="flex justify-end">
              <.button type="submit">Save</.button>
            </div>
          </form>
        </.panel>

        <.panel
          title="Consent screen"
          description="Linked below the authorization prompt users see before granting access."
        >
          <form id="app-consent-form" phx-submit="update_consent_urls" class="space-y-4">
            <.input
              type="url"
              name="tos_url"
              label="Terms of Service URL (optional)"
              value={@app.tos_url}
            />
            <.input
              type="url"
              name="privacy_url"
              label="Privacy Policy URL (optional)"
              value={@app.privacy_url}
            />
            <div class="flex justify-end">
              <.button type="submit">Save</.button>
            </div>
          </form>
        </.panel>
      </div>

      <.panel title="Preview" description="The real login header, with unsaved values applied.">
        <div class="flex items-center justify-end">
          <button
            type="button"
            phx-click="toggle_preview_theme"
            aria-label="Toggle preview theme"
            class="grid size-8 place-items-center rounded-md border border-border hover:bg-muted/50"
          >
            <span :if={@preview_theme == "light"} class="lucide-moon block size-4" />
            <span :if={@preview_theme == "dark"} class="lucide-sun block size-4" />
          </button>
        </div>
        <div class={[
          "mt-2 rounded-lg border border-border bg-background px-5 py-8 text-center",
          @preview_theme == "dark" && "dark"
        ]}>
          <.login_header
            app_name={@app.name}
            logo_url={presence(@draft.logo_url)}
            brand_color={presence(@draft.brand_color)}
            headline={presence(@draft.headline)}
            subtitle={presence(@draft.subtitle)}
          />
        </div>
        <p class="mt-3 text-xs text-muted-foreground">
          <.link
            href={~p"/users/log-in?#{[callback_url: @app.callback_url]}"}
            target="_blank"
            class="underline underline-offset-2 hover:text-foreground"
          >
            Open the full login page
          </.link>
          — saved values only.
        </p>
      </.panel>
    </div>
    """
  end

  # A blank form field means "no value", but `""` would render as a logo with an
  # empty src and an empty style attribute.
  defp presence(""), do: nil
  defp presence(value), do: value

  # The preview renders straight from form params, so it never passes through
  # `App.changeset/2`. Apply the same two guards here: HEEx escaping stops the
  # value breaking out of the attribute, but not CSS-property injection like
  # `red; background: url(...)` inside an otherwise-valid style.
  defp safe_brand_color(value) when is_binary(value) do
    if value =~ ~r/^#[0-9a-fA-F]{6}$/, do: value, else: nil
  end

  defp safe_brand_color(_), do: nil

  defp safe_logo_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> value
      _ -> nil
    end
  end

  defp safe_logo_url(_), do: nil

  # Mirrors the changeset's `validate_length(:headline/:subtitle, max: 200)`,
  # so the preview never shows copy a save would reject.
  defp safe_copy(value) when is_binary(value) do
    if String.length(value) <= 200, do: value, else: nil
  end

  defp safe_copy(_), do: nil

  attr :app, :map, required: true
  attr :roles, :list, required: true
  attr :counts, :map, required: true
  attr :default_role, :string, required: true

  defp roles_tab(assigns) do
    ~H"""
    <.panel
      title="Allowed roles"
      description="Tokens issued for this app carry one of these. Users with no explicit assignment get the default role below."
    >
      <div class="max-w-xl space-y-4">
        <ul class="space-y-1.5">
          <li
            :for={role <- @roles}
            class="flex items-center justify-between rounded-md border border-border px-3 py-2"
          >
            <span class="font-mono text-xs">{role}</span>
            <div class="flex items-center gap-3">
              <span class="font-mono text-xs text-muted-foreground">
                {assignment_count(@counts, role)}
              </span>
              <button
                type="button"
                phx-click="remove_role"
                phx-value-role={role}
                disabled={length(@roles) == 1}
                class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-destructive hover:text-destructive-foreground disabled:pointer-events-none disabled:opacity-40"
              >
                Remove
              </button>
            </div>
          </li>
        </ul>

        <form id="app-add-role-form" phx-submit="add_role" class="flex items-end gap-2">
          <div class="flex-1">
            <.input type="text" name="role" label="Add a role" value="" required />
          </div>
          <.button type="submit">Add</.button>
        </form>

        <div class="border-t border-border pt-4">
          <label class="text-sm font-medium">Default role</label>
          <p class="mt-1 mb-2 text-xs text-muted-foreground">
            What users without an explicit assignment resolve to. Changing it
            re-roles every unassigned user on their next token.
          </p>
          <%!-- A form rather than an on_change select: the confirmation has to
                fire before the change is pushed, and data-confirm needs a real
                phx- binding to hook onto. --%>
          <form
            id="app-default-role-form"
            phx-submit="set_default_role"
            data-confirm="Change the default role? Every user without an explicit assignment gets the new role in their next token."
            class="flex items-center gap-2"
          >
            <.select
              id="app-default-role"
              name="default_role"
              value={@default_role}
              options={Enum.map(@roles, &%{value: &1, label: &1})}
            />
            <.button type="submit" size="sm" variant="outline">Set default</.button>
          </form>
        </div>
      </div>
    </.panel>
    """
  end

  attr :app, :map, required: true
  attr :members, :list, required: true
  attr :roles, :list, required: true
  attr :selected, :any, required: true

  defp members_tab(assigns) do
    ~H"""
    <div class="space-y-3">
      <div
        :if={MapSet.size(@selected) > 0}
        class="flex items-center gap-3 rounded-md border border-border bg-muted/40 px-3 py-2"
      >
        <span class="font-mono text-xs text-muted-foreground">
          {MapSet.size(@selected)} selected
        </span>
        <%!-- A form, not an on_change select: re-roling many users at once
              needs the same confirmation the other wide-blast-radius actions
              get, and data-confirm needs a real phx- binding to attach to. --%>
        <form
          id="bulk-role-form"
          phx-submit="bulk_set_role"
          data-confirm="Apply this role to every selected user?"
          class="ml-auto flex items-center gap-2"
        >
          <.select
            id="bulk-role"
            name="role"
            value=""
            placeholder="Set role to…"
            options={Enum.map(@roles, &%{value: &1, label: &1})}
            align="end"
          />
          <.button type="submit" size="sm">Apply</.button>
        </form>
      </div>

      <.data_table cols={["", "User", "Role"]} empty={@members == []}>
        <tr
          :for={{user, role} <- @members}
          class="border-b border-border/60 transition-colors last:border-0 hover:bg-muted/40"
        >
          <td class="px-3 py-2">
            <input
              type="checkbox"
              aria-label={"Select #{user.email}"}
              checked={MapSet.member?(@selected, to_string(user.id))}
              phx-click="toggle_member"
              phx-value-user_id={user.id}
              class="size-4 rounded border-border"
            />
          </td>
          <td class="px-3 py-2 font-mono text-xs">{user.email}</td>
          <td class="px-3 py-2">
            <.select
              id={"member-role-#{user.id}"}
              value={role}
              options={Enum.map(@roles, &%{value: &1, label: &1})}
              on_change="set_member_role"
              params={%{"user_id" => user.id}}
            />
          </td>
        </tr>
      </.data_table>
    </div>
    """
  end

  attr :app, :map, required: true
  attr :new_secret, :string, default: nil

  # The scopes an OIDC consumer can request — kept in sync with
  # `YouWeb.OIDCController.discovery/2`'s `scopes_supported`.
  @oidc_scopes ~w(email profile roles)

  defp credentials_tab(assigns) do
    assigns = assign(assigns, :oidc_snippet, oidc_snippet(assigns.app))

    ~H"""
    <.panel title="Client credentials" description="Used for the token endpoint and headless login.">
      <dl class="max-w-xl space-y-1.5 text-xs">
        <.kv k="client_id" v={@app.slug} />
        <.kv k="client_secret" v={if @app.client_secret_hash, do: "set", else: "not set"} />
      </dl>

      <div class="mt-4">
        <.button
          variant="outline"
          size="sm"
          phx-click="rotate_secret"
          data-confirm="Rotate the client secret? The current one stops working immediately."
        >
          Rotate secret
        </.button>
      </div>

      <.dialog id="app-secret" open={@new_secret != nil} on_close="dismiss_secret">
        <:title>Client secret</:title>
        <:description>Copy this now. It is hashed at rest and never shown again.</:description>
        <div :if={@new_secret} class="space-y-3">
          <div class="rounded-md border border-border bg-background px-3 py-2 font-mono text-xs break-all text-primary">
            {@new_secret}
          </div>
          <div class="flex items-center justify-between">
            <span class="font-mono text-xs text-muted-foreground">client_id: {@app.slug}</span>
            <.copy_button id="copy-secret" value={@new_secret} label="Copy secret" />
          </div>
        </div>
        <:footer>
          <.button variant="outline" phx-click="dismiss_secret">Done</.button>
        </:footer>
      </.dialog>
    </.panel>

    <.panel
      title="OIDC snippet"
      description="Discovery URL, client_id, and supported scopes for an OIDC-compliant SDK."
    >
      <div class="flex items-start justify-between gap-3">
        <pre class="max-w-xl overflow-x-auto rounded-md border border-border bg-background px-3 py-2 font-mono text-xs whitespace-pre-wrap break-all"><code>{@oidc_snippet}</code></pre>
        <.copy_button id="copy-oidc-snippet" value={@oidc_snippet} label="Copy snippet" />
      </div>
    </.panel>
    """
  end

  defp oidc_snippet(app) do
    """
    discovery_url: #{YouWeb.Endpoint.url()}/.well-known/openid-configuration
    client_id: #{app.slug}
    scopes: #{Enum.join(@oidc_scopes, " ")}
    """
  end

  defp assignment_count(counts, role) do
    case Map.get(counts, role, 0) do
      0 -> "unassigned"
      1 -> "1 user"
      n -> "#{n} users"
    end
  end
end
