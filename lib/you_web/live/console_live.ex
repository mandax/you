defmodule YouWeb.ConsoleLive do
  @moduledoc """
  Admin console at `/console`.

  A single LiveView shell (sidebar + topbar + section views) with a dense,
  mono-accented design: cards and tables, a live
  connection indicator, and `?view=` navigation. Every section is wired to the
  real domain (`You.Admin`, `You.Organizations`, `You.Settings`,
  `You.Audit.Streamer`). No fabricated data.
  """
  use YouWeb, :live_view

  import YouWeb.Components.ConsoleChrome

  alias You.{Admin, Organizations, Accounts, Settings, Webhooks, Roles, IdentityProviders}
  alias You.Audit.Streamer

  @roles ~w(owner admin member)

  # Shown but locked. An admin should be able to see that password login
  # exists and cannot be switched off, rather than wonder where it went.
  @mandatory_features [
    {"Password sign-in", "The fallback every account has. Disabling it would lock everyone out."},
    {"Two-factor authentication",
     "TOTP and emailed codes. A switch that turns a second factor off is a downgrade attack with a friendly label, and would strand enrolled accounts."},
    {"Sessions and tokens", "How You proves who a visitor is."},
    {"Audit trail", "Records privileged actions. Not optional."}
  ]

  # One line per section, rendered above its view. Says what the section is for
  # rather than restating its title.
  @section_copy %{
    "overview" => "Instance at a glance: accounts, registered apps, and recent activity.",
    "users" =>
      "Everyone with an account here. Filter by app, role, or status, and manage a user's access from their row.",
    "apps" =>
      "Services that delegate authentication to You. Each one gets a client id, a secret, and its own roles and login branding.",
    "providers" =>
      "Upstream identity providers users can sign in with. Configured once here, then enabled per app. A provider switched off is refused everywhere, not just hidden.",
    "orgs" => "Groups of users that share app access.",
    "audit" =>
      "Privileged actions, newest first. This is the live in-memory view; configure the audit webhook for retention.",
    "webhooks" =>
      "Signed outbound events. Use them to react to identity changes in your own systems.",
    "features" =>
      "What this instance offers. Switching something off removes it from the console and the login page.",
    "settings" =>
      "Instance-wide tuning: token lifetimes, Erlang distribution, and integration secrets."
  }

  @feature_copy %{
    feature_passkeys: {"Passkeys", "WebAuthn sign-in and per-user passkey management."},
    feature_magic_link: {"Magic links", "Passwordless sign-in by emailed link."},
    feature_social_login: {"Social sign-in", "Upstream identity providers on the login page."},
    feature_organizations: {"Organizations", "Teams that share app access. Still incomplete."},
    feature_webhooks: {"Webhooks", "Signed outbound events."}
  }

  # Write-only in the console: never rendered into the DOM, blank on save
  # keeps the current value, cleared via the explicit "clear" button.
  @secret_settings [:erlang_cookie, :scim_bearer_token]

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
       nav: nav(),
       view: "overview",
       node_name: Node.self(),
       roles: @roles,
       new_secret: nil,
       secret_app: nil,
       selected_org: nil,
       members: [],
       audit_filter: "",
       audit_app_filter: "",
       webhook_secret: nil,
       webhook_endpoint: nil,
       user_filters: %{},
       editing_user: nil,
       editing_provider: nil,
       new_provider_open: false,
       new_provider_preset: "generic",
       discovery: nil,
       base_url: YouWeb.Endpoint.url(),
       oidc_providers:
         Application.get_env(:you, :oidc_providers, %{}) |> Map.keys() |> Enum.sort(),
       saved: false,
       app_filter: "",
       provider_filter: "",
       webhook_filter: "",
       features: Settings.features() |> Map.new(&{&1, Settings.get(&1)}),
       onboarding: not Settings.get(:onboarding_completed)
     )
     |> load_data()
     |> load_settings()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # First admin login lands here rather than on an overview of a console
    # they have not shaped yet.
    default = if socket.assigns.onboarding, do: "features", else: "overview"
    view = params["view"] || default
    view = if Enum.any?(nav(), &(&1.id == view)), do: view, else: default
    {:noreply, assign(socket, view: view, saved: false)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_data(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── users ─────────────────────────────────────────────────────
  @impl true
  def handle_event("logout_user", %{"id" => id}, socket) do
    user = Admin.get_user!(id)
    Accounts.delete_all_user_tokens(user)
    audit_admin(socket, "logout_user", user.email)

    {:noreply,
     socket |> load_data() |> put_flash(:info, "All sessions revoked for #{user.email}.")}
  end

  def handle_event("anonymize_user", %{"id" => id}, socket) do
    user = Admin.get_user!(id)
    {:ok, _} = Accounts.anonymize_user(user)
    audit_admin(socket, "anonymize_user", user.email)
    {:noreply, socket |> load_data() |> put_flash(:info, "User anonymized.")}
  end

  # ── apps ──────────────────────────────────────────────────────
  def handle_event("create_app", params, socket) do
    case Admin.create_app(
           Map.take(params, [
             "name",
             "slug",
             "callback_url",
             "launch_url",
             "logo_url",
             "brand_color",
             "first_party"
           ])
         ) do
      {:ok, app, secret} ->
        {:noreply, socket |> load_data() |> assign(new_secret: secret, secret_app: app)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create app: #{error_summary(changeset)}")}
    end
  end

  def handle_event("delete_app", %{"id" => id}, socket) do
    # `Admin.delete_app/1` emits the audit event itself; a second one here
    # would record the same removal twice under two different shapes.
    case id |> Admin.get_app!() |> Admin.delete_app() do
      {:ok, _app} ->
        {:noreply, socket |> load_data() |> put_flash(:info, "App deleted.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete: #{error_summary(changeset)}")}
    end
  end

  # ── identity providers ───────────────────────────────────────
  def handle_event("new_provider", _params, socket) do
    {:noreply,
     assign(socket, new_provider_open: true, new_provider_preset: "generic", discovery: nil)}
  end

  def handle_event("cancel_new_provider", _params, socket) do
    {:noreply, assign(socket, new_provider_open: false, discovery: nil)}
  end

  def handle_event("select_new_provider_preset", %{"value" => preset}, socket) do
    {:noreply, assign(socket, new_provider_preset: preset, discovery: nil)}
  end

  def handle_event("discover_provider", %{"issuer" => issuer}, socket) do
    socket =
      case IdentityProviders.discover(issuer) do
        {:ok, attrs} -> assign(socket, discovery: {:ok, attrs})
        {:error, reason} -> assign(socket, discovery: {:error, reason})
      end

    {:noreply, socket}
  end

  def handle_event("create_provider", params, socket) do
    preset = params["preset"] || "generic"
    attrs = provider_create_attrs(params)

    case IdentityProviders.create_provider_from_preset(preset, attrs) do
      {:ok, provider} ->
        audit_admin(socket, "create_provider", provider.slug)

        {:noreply,
         socket
         |> load_data()
         |> assign(new_provider_open: false, discovery: nil)
         |> put_flash(:info, "Provider created.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not create provider: #{error_summary(changeset)}")}

      {:error, :unknown_preset} ->
        {:noreply, put_flash(socket, :error, "Unknown preset.")}
    end
  end

  def handle_event("edit_provider", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_provider: IdentityProviders.get_provider!(id))}
  end

  def handle_event("cancel_edit_provider", _params, socket) do
    {:noreply, assign(socket, editing_provider: nil)}
  end

  def handle_event("update_provider", params, socket) do
    provider = IdentityProviders.get_provider!(params["provider_id"])
    attrs = provider_update_attrs(params)

    case IdentityProviders.update_provider(provider, attrs) do
      {:ok, provider} ->
        audit_admin(socket, "update_provider", provider.slug)

        {:noreply,
         socket
         |> load_data()
         |> assign(editing_provider: nil)
         |> put_flash(:info, "Provider updated.")}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not update provider: #{error_summary(changeset)}")}
    end
  end

  def handle_event("toggle_provider", %{"id" => id}, socket) do
    provider = IdentityProviders.get_provider!(id)

    {:ok, updated} =
      IdentityProviders.update_provider(provider, %{"enabled" => !provider.enabled})

    audit_admin(
      socket,
      if(updated.enabled, do: "enable_provider", else: "disable_provider"),
      updated.slug
    )

    {:noreply, load_data(socket)}
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    provider = IdentityProviders.get_provider!(id)
    {:ok, _} = IdentityProviders.delete_provider(provider)
    audit_admin(socket, "delete_provider", provider.slug)
    {:noreply, socket |> load_data() |> put_flash(:info, "Provider deleted.")}
  end

  def handle_event("filter_users", %{"filter_key" => key, "value" => value}, socket) do
    {:noreply, assign(socket, user_filters: Map.put(socket.assigns.user_filters, key, value))}
  end

  def handle_event("filter_users", params, socket) do
    filters = Map.merge(socket.assigns.user_filters, Map.take(params, ["email"]))
    {:noreply, assign(socket, user_filters: filters)}
  end

  def handle_event("set_you_role", %{"user_id" => user_id} = params, socket) do
    role = params["value"] || params["role"]
    user = Admin.get_user!(user_id)
    self? = user.id == socket.assigns.current_scope.user.id

    socket =
      cond do
        role == "user" and user.is_admin and self? ->
          put_flash(socket, :error, "You cannot revoke your own admin rights.")

        role == "admin" and not user.is_admin ->
          Admin.promote_admin(user)
          audit_admin(socket, "promote_admin", user.email)
          load_data(socket)

        role == "user" and user.is_admin ->
          Admin.demote_admin(user)
          audit_admin(socket, "demote_admin", user.email)
          load_data(socket)

        true ->
          socket
      end

    {:noreply, refresh_editing_user(socket, user_id)}
  end

  def handle_event("edit_user", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_user: Admin.get_user!(id))}
  end

  def handle_event("cancel_edit_user", _params, socket) do
    {:noreply, assign(socket, editing_user: nil)}
  end

  # `value` is what <.select> pushes; `role` is kept for any caller that still
  # names the field itself.
  def handle_event("save_app_role", params, socket) do
    app = Admin.get_app!(params["app_id"])
    user = Admin.get_user!(params["user_id"])

    case Roles.set_role(app, user, params["value"] || params["role"]) do
      {:ok, _} ->
        {:noreply, socket |> load_data() |> refresh_editing_user(params["user_id"])}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Role is not allowed for this app.")}
    end
  end

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, new_secret: nil, secret_app: nil)}

  # ── orgs ──────────────────────────────────────────────────────
  def handle_event("create_org", params, socket) do
    case Organizations.create_organization(Map.take(params, ["name", "slug"])) do
      {:ok, _org} ->
        {:noreply, socket |> load_data() |> put_flash(:info, "Organization created.")}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, "Could not create org: #{error_summary(cs)}")}
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
          {:ok, _} ->
            {:noreply, socket |> select_org(org.id) |> put_flash(:info, "Member added.")}

          {:error, cs} ->
            {:noreply, put_flash(socket, :error, "Could not add: #{error_summary(cs)}")}
        end
    end
  end

  def handle_event("update_role", %{"user_id" => uid} = params, socket) do
    org = socket.assigns.selected_org
    Organizations.update_member_role(org, Admin.get_user!(uid), params["value"] || params["role"])
    {:noreply, select_org(socket, org.id)}
  end

  def handle_event("remove_member", %{"user_id" => uid}, socket) do
    org = socket.assigns.selected_org
    Organizations.remove_member(org, Admin.get_user!(uid))
    {:noreply, socket |> select_org(org.id) |> put_flash(:info, "Member removed.")}
  end

  # ── settings ──────────────────────────────────────────────────
  def handle_event("filter_apps", %{"query" => query}, socket) do
    {:noreply, assign(socket, app_filter: query)}
  end

  def handle_event("filter_providers", %{"query" => query}, socket) do
    {:noreply, assign(socket, provider_filter: query)}
  end

  def handle_event("filter_webhooks", %{"query" => query}, socket) do
    {:noreply, assign(socket, webhook_filter: query)}
  end

  def handle_event("filter_audit", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :audit_filter, filter)}
  end

  def handle_event("filter_audit_app", %{"value" => app_slug}, socket) do
    {:noreply, assign(socket, :audit_app_filter, app_slug)}
  end

  # ── webhooks ──────────────────────────────────────────────────
  def handle_event("create_webhook", params, socket) do
    events = Map.get(params, "events", %{})

    attrs = %{
      "url" => params["url"],
      "events" => for({event, "true"} <- events, do: event)
    }

    case Webhooks.create_endpoint(attrs) do
      {:ok, endpoint} ->
        audit_admin(socket, "create_webhook", endpoint.url)

        {:noreply,
         socket
         |> load_data()
         |> assign(webhook_secret: endpoint.secret, webhook_endpoint: endpoint)}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not create endpoint: #{error_summary(changeset)}")}
    end
  end

  def handle_event("toggle_webhook", %{"id" => id}, socket) do
    endpoint = Webhooks.get_endpoint!(id)
    {:ok, _} = Webhooks.update_endpoint(endpoint, %{"enabled" => !endpoint.enabled})
    {:noreply, load_data(socket)}
  end

  def handle_event("rotate_webhook_secret", %{"id" => id}, socket) do
    endpoint = Webhooks.get_endpoint!(id)
    {:ok, rotated} = Webhooks.rotate_secret(endpoint)
    audit_admin(socket, "rotate_webhook_secret", endpoint.url)

    {:noreply,
     socket
     |> load_data()
     |> assign(webhook_secret: rotated.secret, webhook_endpoint: rotated)}
  end

  def handle_event("delete_webhook", %{"id" => id}, socket) do
    endpoint = Webhooks.get_endpoint!(id)
    {:ok, _} = Webhooks.delete_endpoint(endpoint)
    audit_admin(socket, "delete_webhook", endpoint.url)
    {:noreply, socket |> load_data() |> put_flash(:info, "Endpoint deleted.")}
  end

  def handle_event("dismiss_webhook_secret", _params, socket) do
    {:noreply, assign(socket, webhook_secret: nil, webhook_endpoint: nil)}
  end

  def handle_event("save_features", params, socket) do
    enabled = Map.get(params, "features", %{})

    for key <- Settings.features() do
      Settings.set(key, Map.get(enabled, Atom.to_string(key)) == "true")
    end

    Settings.set(:onboarding_completed, true)
    audit_admin(socket, "update_features", "instance")

    {:noreply,
     socket
     |> assign(
       features: Settings.features() |> Map.new(&{&1, Settings.get(&1)}),
       onboarding: false
     )
     |> put_flash(:info, "Features updated.")}
  end

  def handle_event("save_settings", params, socket) do
    Enum.each(@settings_fields, fn %{key: key} ->
      raw = params[Atom.to_string(key)]

      if is_binary(raw) and not (key in @secret_settings and raw == "") do
        Settings.set(key, parse_value(raw))
      end
    end)

    You.Accounts.CookieSync.apply_cookie()
    You.Audit.Streamer.reload()
    {:noreply, socket |> load_settings() |> assign(saved: true)}
  end

  def handle_event("clear_setting", %{"key" => key}, socket) do
    # Resolve against the allowlist rather than converting first: an unknown key
    # would raise in `String.to_existing_atom/1` before any membership check.
    case Enum.find(@secret_settings, &(Atom.to_string(&1) == key)) do
      nil ->
        {:noreply, socket}

      setting ->
        Settings.set(setting, "")
        You.Accounts.CookieSync.apply_cookie()
        You.Audit.Streamer.reload()
        {:noreply, load_settings(socket)}
    end
  end

  # Case-insensitive substring match across the given fields. Filtering is
  # presentation only — nothing is re-queried, so a search cannot change what a
  # bulk action would touch.
  defp search(rows, "", _fields), do: rows

  defp search(rows, query, fields) do
    needle = String.downcase(query)

    Enum.filter(rows, fn row ->
      Enum.any?(fields, fn field ->
        row |> Map.get(field) |> to_string() |> String.downcase() |> String.contains?(needle)
      end)
    end)
  end

  # ── data loading ──────────────────────────────────────────────
  defp refresh_editing_user(socket, user_id) do
    case socket.assigns[:editing_user] do
      nil ->
        socket

      %{id: id} ->
        if to_string(id) == to_string(user_id) do
          assign(socket, editing_user: Admin.get_user!(id))
        else
          socket
        end
    end
  end

  defp audit_admin(socket, action, target) do
    :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
      admin_user_id: socket.assigns.current_scope.user.id,
      action: action,
      target: target
    })
  end

  defp load_data(socket) do
    org = socket.assigns[:selected_org]

    socket
    |> assign(
      users: Admin.list_users_with_stats(),
      apps: Admin.list_apps(),
      orgs: Organizations.list_organizations_with_counts(),
      events: Streamer.recent(),
      endpoints: Webhooks.list_endpoints(),
      assignments: Roles.all_assignments(),
      providers: IdentityProviders.list_providers()
    )
    |> assign(members: if(org, do: Organizations.list_members(org), else: []))
  end

  # Drops blank/missing keys so a preset's endpoint template (or, on edit, the
  # provider's own stored values) is left in place rather than clobbered by an
  # empty form field. `create_provider_from_preset/2` merges these attrs over
  # the preset, so a key's absence here is what makes the preset default win.
  defp provider_create_attrs(params) do
    ~w(slug display_name client_id client_secret issuer authorize_url token_url userinfo_url scopes)
    |> Enum.reduce(%{}, fn key, attrs ->
      case params[key] do
        value when is_binary(value) and value != "" -> Map.put(attrs, key, value)
        _ -> attrs
      end
    end)
  end

  defp provider_update_attrs(params) do
    Map.take(params, ~w(
      display_name client_id client_secret issuer authorize_url token_url userinfo_url scopes
      sort_order
    ))
  end

  defp discovery_value({:ok, attrs}, key), do: Map.get(attrs, key)
  defp discovery_value(_discovery, _key), do: nil

  defp load_settings(socket),
    do: assign(socket, settings: Settings.all())

  defp select_org(socket, id) do
    case Organizations.get_organization(id) do
      nil -> assign(socket, selected_org: nil, members: [])
      org -> assign(socket, selected_org: org, members: Organizations.list_members(org))
    end
  end

  defp parse_value(raw) do
    if raw =~ ~r/^\d+$/, do: String.to_integer(raw), else: raw
  end

  defp section_copy(view), do: Map.get(@section_copy, view)

  defp nav_label(view), do: Enum.find_value(nav(), "", &if(&1.id == view, do: &1.label))

  # ── shell ─────────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    ~H"""
    <.console_shell nav={@nav} active={@view} title={nav_label(@view)} node_name={@node_name}>
      <div class="mb-5">
        <h1 class="text-lg font-medium">{nav_label(@view)}</h1>
        <p :if={section_copy(@view)} class="mt-1 max-w-2xl text-sm text-muted-foreground">
          {section_copy(@view)}
        </p>
      </div>

      <%= case @view do %>
        <% "overview" -> %>
          <.overview users={@users} apps={@apps} orgs={@orgs} events={@events} />
        <% "users" -> %>
          <.users_view
            users={@users}
            apps={@apps}
            assignments={@assignments}
            filters={@user_filters}
            current_scope={@current_scope}
            editing_user={@editing_user}
          />
        <% "apps" -> %>
          <.apps_view
            apps={search(@apps, @app_filter, [:name, :slug])}
            app_filter={@app_filter}
            new_secret={@new_secret}
            secret_app={@secret_app}
          />
        <% "providers" -> %>
          <.providers_view
            providers={search(@providers, @provider_filter, [:display_name, :slug])}
            provider_filter={@provider_filter}
            base_url={@base_url}
            editing_provider={@editing_provider}
            new_provider_open={@new_provider_open}
            new_provider_preset={@new_provider_preset}
            discovery={@discovery}
          />
        <% "orgs" -> %>
          <.orgs_view orgs={@orgs} selected={@selected_org} members={@members} roles={@roles} />
        <% "audit" -> %>
          <.audit_view
            events={@events}
            apps={@apps}
            audit_filter={@audit_filter}
            audit_app_filter={@audit_app_filter}
          />
        <% "webhooks" -> %>
          <.webhooks_view
            endpoints={search(@endpoints, @webhook_filter, [:url])}
            webhook_filter={@webhook_filter}
            events={Webhooks.events()}
            webhook_secret={@webhook_secret}
            webhook_endpoint={@webhook_endpoint}
          />
        <% "features" -> %>
          <.features_view features={@features} onboarding={@onboarding} />
        <% "settings" -> %>
          <.settings_view
            settings={@settings}
            base_url={@base_url}
            oidc_providers={@oidc_providers}
            saved={@saved}
          />
      <% end %>

      <Layouts.flash_group flash={@flash} />
    </.console_shell>
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
  attr :apps, :list, required: true
  attr :assignments, :map, required: true
  attr :filters, :map, required: true
  attr :current_scope, :map, required: true
  attr :editing_user, :map, default: nil

  defp users_view(assigns) do
    assigns =
      assign(assigns,
        filtered: filter_users(assigns.users, assigns.filters, assigns.assignments)
      )

    ~H"""
    <div class="space-y-4">
      <div class="flex flex-wrap items-center gap-3">
        <span class="font-mono text-xs text-muted-foreground">
          <span class="text-foreground">{length(@filtered)}</span> of {length(@users)} users
        </span>
        <div class="flex flex-wrap items-center gap-2">
          <form phx-change="filter_users">
            <input
              type="text"
              name="email"
              value={@filters["email"]}
              placeholder="filter email"
              class="h-8 w-44 rounded-md border border-input bg-background px-3 font-mono text-xs placeholder:text-muted-foreground/60"
            />
          </form>
          <.select
            id="filter-status"
            value={@filters["status"]}
            placeholder="all status"
            options={[
              %{value: "", label: "all status"},
              %{value: "confirmed", label: "confirmed"},
              %{value: "unconfirmed", label: "unconfirmed"}
            ]}
            on_change="filter_users"
            params={%{"filter_key" => "status"}}
          />
          <.select
            id="filter-app"
            value={@filters["app"]}
            placeholder="all apps"
            options={
              [%{value: "", label: "all apps"}] ++
                Enum.map(@apps, &%{value: to_string(&1.id), label: &1.name})
            }
            on_change="filter_users"
            params={%{"filter_key" => "app"}}
          />
          <.select
            id="filter-role"
            value={@filters["role"]}
            placeholder="all roles"
            options={
              [%{value: "", label: "all roles"}] ++
                Enum.map(all_roles(@apps), &%{value: &1, label: &1})
            }
            on_change="filter_users"
            params={%{"filter_key" => "role"}}
          />
        </div>
      </div>

      <.data_table cols={["Email", "Status", "You", "Access", ""]} empty={@filtered == []}>
        <%!-- The row opens the detail sheet, but the binding sits on the data
              cells rather than the <tr>: LiveView delegates clicks from the
              document root, so stopping propagation around the action buttons
              to keep them from also opening the sheet would swallow their own
              phx-click on the way up. --%>
        <tr
          :for={row <- @filtered}
          class="border-b border-border/60 transition-colors last:border-0 hover:bg-muted/40"
        >
          <td
            phx-click="edit_user"
            phx-value-id={row.user.id}
            class="cursor-pointer px-3 py-2 font-mono text-xs text-foreground/90"
          >
            {row.user.email}
          </td>
          <td phx-click="edit_user" phx-value-id={row.user.id} class="cursor-pointer px-3 py-2">
            <.status_badge status={if row.user.confirmed_at, do: "running", else: "idle"} />
          </td>
          <td
            phx-click="edit_user"
            phx-value-id={row.user.id}
            class={[
              "cursor-pointer px-3 py-2 font-mono text-xs",
              if(row.user.is_admin, do: "text-primary", else: "text-muted-foreground")
            ]}
          >
            {if row.user.is_admin, do: "admin", else: "user"}
          </td>
          <td phx-click="edit_user" phx-value-id={row.user.id} class="cursor-pointer px-3 py-2">
            <.access_summary access={access_summary(@assignments, @apps, row.user.id)} />
          </td>
          <td class="px-3 py-2 text-right">
            <div class="flex items-center justify-end gap-1">
              <button
                type="button"
                phx-click="edit_user"
                phx-value-id={row.user.id}
                class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              >
                Edit
              </button>
              <button
                :if={row.user.id != @current_scope.user.id}
                type="button"
                phx-click="logout_user"
                phx-value-id={row.user.id}
                data-confirm={"Revoke all sessions for #{row.user.email}?"}
                class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              >
                Log out
              </button>
              <button
                :if={row.user.id != @current_scope.user.id}
                type="button"
                phx-click="anonymize_user"
                phx-value-id={row.user.id}
                data-confirm={"Anonymize #{row.user.email}? Personal data is wiped permanently and the account can no longer log in."}
                class="rounded px-2 py-1 text-xs text-signal-down transition-colors hover:bg-destructive hover:text-destructive-foreground"
              >
                Anonymize
              </button>
            </div>
          </td>
        </tr>
      </.data_table>

      <.sheet id="edit-user" open={@editing_user != nil} on_close="cancel_edit_user">
        <:title>{@editing_user && @editing_user.email}</:title>
        <:description>
          Roles on You and on each app. Changes apply immediately.
        </:description>
        <div :if={@editing_user} class="space-y-5">
          <section class="space-y-2">
            <h3 class="font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
              Instance
            </h3>
            <div class="flex items-center justify-between gap-4">
              <span class="text-sm">You</span>
              <.select
                id="edit-you-role"
                align="end"
                value={if @editing_user.is_admin, do: "admin", else: "user"}
                options={[%{value: "user", label: "user"}, %{value: "admin", label: "admin"}]}
                on_change="set_you_role"
                params={%{"user_id" => @editing_user.id}}
              />
            </div>
          </section>

          <section class="space-y-2">
            <h3 class="font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
              Apps
            </h3>
            <div
              :for={app <- @apps}
              class="flex items-center justify-between gap-4 border-b border-border/50 py-1.5 last:border-0"
            >
              <span class="min-w-0 truncate text-sm">{app.name}</span>
              <.select
                id={"edit-app-role-#{app.id}"}
                align="end"
                value={app_role(@assignments, @editing_user.id, app.id)}
                options={Enum.map(app.allowed_roles || ["user", "admin"], &%{value: &1, label: &1})}
                on_change="save_app_role"
                params={%{"app_id" => app.id, "user_id" => @editing_user.id}}
              />
            </div>
          </section>
        </div>
        <:footer>
          <.button variant="outline" phx-click="cancel_edit_user">Done</.button>
        </:footer>
      </.sheet>
    </div>
    """
  end

  # Per-app roles for one user, condensed into a single cell.
  #
  # A column per app does not survive contact with a real instance: it grows
  # without bound and nearly every cell reads "user". What an admin scans for
  # is the exception, so elevated roles are shown by name and the rest collapses
  # into a count.
  attr :access, :map, required: true

  defp access_summary(assigns) do
    ~H"""
    <div :if={@access.total == 0} class="font-mono text-xs text-muted-foreground/60">—</div>
    <%!-- One line, always: the badges truncate before the count does, so rows
          keep an even height however long an app name is. --%>
    <div :if={@access.total > 0} class="flex max-w-[22rem] items-center gap-1.5">
      <div class="flex min-w-0 items-center gap-1.5 overflow-hidden">
        <span
          :for={{role, app} <- @access.elevated}
          class="truncate rounded bg-primary/10 px-1.5 py-0.5 font-mono text-[11px] text-primary"
          title={"#{role} on #{app}"}
        >
          {role}·{app}
        </span>
      </div>
      <span :if={@access.rest > 0} class="shrink-0 font-mono text-[11px] text-muted-foreground">
        +{@access.rest} {if @access.rest == 1, do: "app", else: "apps"}
      </span>
    </div>
    """
  end

  @elevated_shown 2

  defp access_summary(assignments, apps, user_id) do
    roles = Map.get(assignments, user_id, %{})
    names = Map.new(apps, &{&1.id, &1.name})

    elevated =
      for {app_id, role} <- roles,
          role != "user",
          Map.has_key?(names, app_id),
          do: {role, names[app_id]}

    shown = Enum.take(Enum.sort(elevated), @elevated_shown)

    %{total: map_size(roles), elevated: shown, rest: map_size(roles) - length(shown)}
  end

  defp all_roles(apps) do
    apps
    |> Enum.flat_map(&(&1.allowed_roles || ["user", "admin"]))
    |> Enum.uniq()
  end

  defp app_role(assignments, user_id, app_id) do
    get_in(assignments, [user_id, app_id]) || "user"
  end

  defp filter_users(users, filters, assignments) do
    Enum.filter(users, fn row ->
      email_match?(row.user, filters["email"]) and
        status_match?(row.user, filters["status"]) and
        app_roles_match?(row.user, filters, assignments)
    end)
  end

  defp email_match?(_user, nil), do: true
  defp email_match?(_user, ""), do: true

  defp email_match?(user, filter),
    do: String.contains?(String.downcase(user.email || ""), String.downcase(filter))

  defp status_match?(_user, nil), do: true
  defp status_match?(_user, ""), do: true
  defp status_match?(user, "confirmed"), do: not is_nil(user.confirmed_at)
  defp status_match?(user, "unconfirmed"), do: is_nil(user.confirmed_at)

  defp app_roles_match?(user, filters, assignments) do
    app_id = present(filters["app"])
    role = present(filters["role"])
    user_roles = Map.get(assignments, user.id, %{})

    cond do
      app_id && role ->
        Map.get(user_roles, String.to_integer(app_id)) == role

      app_id ->
        Map.has_key?(user_roles, String.to_integer(app_id))

      role ->
        role in Map.values(user_roles)

      true ->
        true
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value), do: value

  # ── section: apps ─────────────────────────────────────────────
  attr :apps, :list, required: true
  attr :app_filter, :string, default: ""
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
            <.input type="url" name="launch_url" label="Launch URL (optional)" value="" />
            <.input type="url" name="logo_url" label="Logo URL (optional)" value="" />
            <.input
              type="text"
              name="brand_color"
              label="Brand color (optional)"
              value=""
              placeholder="#7c3aed"
            />
            <.input
              type="checkbox"
              name="first_party"
              label="First-party app"
              value="true"
              checked={false}
            />
            <div class="flex justify-end">
              <.button type="submit">Create</.button>
            </div>
          </form>
        </.dialog>
      </div>

      <.list_search
        event="filter_apps"
        value={@app_filter}
        placeholder="Search apps by name or client id"
        count={length(@apps)}
        noun="apps"
      />

      <.data_table cols={~w(Name Client-ID Callback 1st-party Secret) ++ [""]} empty={@apps == []}>
        <tr
          :for={app <- @apps}
          class="border-b border-border/60 transition-colors last:border-0 hover:bg-muted/40"
        >
          <td class="px-3 py-2 text-xs">{app.name}</td>
          <td class="px-3 py-2 font-mono text-xs text-foreground/90">{app.slug}</td>
          <td class="px-3 py-2 font-mono text-xs text-muted-foreground">{app.callback_url}</td>
          <td class="px-3 py-2">
            <.badge :if={app.first_party} variant="info">1st-party</.badge>
            <span :if={!app.first_party} class="font-mono text-xs text-muted-foreground">
              &mdash;
            </span>
          </td>
          <td class="px-3 py-2">
            <.status_badge status={if app.client_secret_hash, do: "running", else: "idle"} />
          </td>
          <td class="px-3 py-2 text-right whitespace-nowrap">
            <.link
              navigate={~p"/console/apps/#{app.slug}"}
              class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
            >
              Manage
            </.link>
            <button
              type="button"
              phx-click="delete_app"
              phx-value-id={app.id}
              data-confirm={delete_app_confirm(app)}
              class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-destructive hover:text-destructive-foreground"
            >
              Delete
            </button>
          </td>
        </tr>
      </.data_table>

      <.dialog id="app-secret" open={@new_secret != nil} on_close="dismiss_secret">
        <:title>Client secret</:title>
        <:description>Copy this now. It is hashed at rest and never shown again.</:description>
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

  # Computed at render time rather than carried as an assign: app counts are a
  # handful of rows in an admin console, and staleness here would understate
  # exactly the number an admin is relying on to decide.
  defp delete_app_confirm(app) do
    %{consents: consents, role_assignments: roles} = Admin.deletion_impact(app)

    "Delete app “#{app.name}”? This permanently deletes #{consents} #{pluralize(consents, "consent", "consents")} and #{roles} #{pluralize(roles, "role assignment", "role assignments")}. This cannot be undone."
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_count, _singular, plural), do: plural

  # ── section: providers ────────────────────────────────────────
  attr :providers, :list, required: true
  attr :provider_filter, :string, default: ""
  attr :base_url, :string, required: true
  attr :editing_provider, :any, default: nil
  attr :new_provider_open, :boolean, required: true
  attr :new_provider_preset, :string, required: true
  attr :discovery, :any, default: nil

  defp providers_view(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <span class="font-mono text-xs text-muted-foreground">
          {length(@providers)} providers
        </span>
        <.button size="sm" phx-click="new_provider">
          <span class="lucide-plus size-4 block" /> New provider
        </.button>
      </div>

      <.list_search
        event="filter_providers"
        value={@provider_filter}
        placeholder="Search providers by name or slug"
        count={length(@providers)}
        noun="shown"
      />

      <.data_table
        cols={~w(Slug Kind Display Client-ID Enabled Order) ++ [""]}
        empty={@providers == []}
      >
        <tr
          :for={p <- @providers}
          class="border-b border-border/60 transition-colors last:border-0 hover:bg-muted/40"
        >
          <td class="px-3 py-2 font-mono text-xs text-foreground/90">{p.slug}</td>
          <td class="px-3 py-2 font-mono text-xs text-muted-foreground">{p.kind}</td>
          <td class="px-3 py-2 text-xs">{p.display_name}</td>
          <td class="px-3 py-2 font-mono text-xs text-muted-foreground">{p.client_id || "—"}</td>
          <td class="px-3 py-2">
            <.switch checked={p.enabled} phx-click="toggle_provider" phx-value-id={p.id} />
          </td>
          <td class="px-3 py-2 font-mono text-xs text-muted-foreground">{p.sort_order}</td>
          <td class="px-3 py-2 text-right whitespace-nowrap">
            <button
              type="button"
              phx-click="edit_provider"
              phx-value-id={p.id}
              class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            >
              Edit
            </button>
            <button
              type="button"
              phx-click="delete_provider"
              phx-value-id={p.id}
              data-confirm={"Delete provider “#{p.display_name}”? Logins via this provider will stop working immediately."}
              class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-destructive hover:text-destructive-foreground"
            >
              Delete
            </button>
          </td>
        </tr>
      </.data_table>

      <.dialog id="new-provider" open={@new_provider_open} on_close="cancel_new_provider">
        <:title>New provider</:title>
        <:description>Create from a preset, or configure a generic OIDC provider.</:description>

        <div class="space-y-4">
          <div class="space-y-1.5">
            <span class="block font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
              Preset
            </span>
            <.select
              id="new-provider-preset"
              value={@new_provider_preset}
              options={
                Enum.map(
                  IdentityProviders.Presets.names(),
                  &%{value: &1, label: String.capitalize(&1)}
                )
              }
              on_change="select_new_provider_preset"
              params={%{}}
            />
          </div>

          <.provider_setup preset={@new_provider_preset} base_url={@base_url} />

          <div
            :if={@new_provider_preset == "generic"}
            class="space-y-3 rounded-md border border-border bg-muted/30 p-3"
          >
            <form phx-submit="discover_provider" class="flex items-end gap-2 [&_>div]:mb-0">
              <div class="flex-1">
                <.input
                  type="url"
                  name="issuer"
                  label="Discover from issuer URL"
                  value={discovery_value(@discovery, :issuer)}
                  placeholder="https://issuer.example.com"
                />
              </div>
              <.button type="submit" variant="outline" size="sm">Discover</.button>
            </form>
            <p :if={match?({:error, _}, @discovery)} class="font-mono text-[11px] text-signal-down">
              Discovery failed: {elem(@discovery, 1)}
            </p>
            <p :if={match?({:ok, _}, @discovery)} class="font-mono text-[11px] text-signal-ok">
              Discovered endpoints below — review before creating.
            </p>
          </div>

          <form id="new-provider-form" phx-submit="create_provider" class="space-y-3">
            <input type="hidden" name="preset" value={@new_provider_preset} />
            <.input type="text" name="slug" label="Slug" value="" required />
            <.input type="text" name="display_name" label="Display name (optional)" value="" />
            <.input type="text" name="client_id" label="Client ID" value="" />
            <.input
              type="password"
              name="client_secret"
              label="Client secret"
              value=""
              autocomplete="off"
            />

            <div :if={@new_provider_preset == "generic"} class="space-y-3">
              <.input
                type="url"
                name="issuer"
                label="Issuer"
                value={discovery_value(@discovery, :issuer)}
              />
              <.input
                type="url"
                name="authorize_url"
                label="Authorize URL"
                value={discovery_value(@discovery, :authorize_url)}
              />
              <.input
                type="url"
                name="token_url"
                label="Token URL"
                value={discovery_value(@discovery, :token_url)}
              />
              <.input
                type="url"
                name="userinfo_url"
                label="Userinfo URL"
                value={discovery_value(@discovery, :userinfo_url)}
              />
              <.input
                type="text"
                name="scopes"
                label="Scopes"
                value={discovery_value(@discovery, :scopes)}
              />
            </div>

            <div class="flex justify-end gap-2">
              <.button type="button" variant="outline" phx-click="cancel_new_provider">
                Cancel
              </.button>
              <.button type="submit">Create</.button>
            </div>
          </form>
        </div>
      </.dialog>

      <.sheet id="edit-provider" open={@editing_provider != nil} on_close="cancel_edit_provider">
        <:title>{@editing_provider && @editing_provider.display_name}</:title>
        <:description>
          {@editing_provider && @editing_provider.slug} · {@editing_provider && @editing_provider.kind}
        </:description>
        <form
          :if={@editing_provider}
          id="edit-provider-form"
          phx-submit="update_provider"
          class="space-y-3"
        >
          <input type="hidden" name="provider_id" value={@editing_provider.id} />
          <.input
            type="text"
            name="display_name"
            label="Display name"
            value={@editing_provider.display_name}
            required
          />
          <.input type="text" name="client_id" label="Client ID" value={@editing_provider.client_id} />
          <.input
            type="password"
            name="client_secret"
            label="Client secret"
            value=""
            placeholder="unchanged — enter to replace"
            autocomplete="off"
          />
          <.input type="url" name="issuer" label="Issuer" value={@editing_provider.issuer} />
          <.input
            type="url"
            name="authorize_url"
            label="Authorize URL"
            value={@editing_provider.authorize_url}
          />
          <.input type="url" name="token_url" label="Token URL" value={@editing_provider.token_url} />
          <.input
            type="url"
            name="userinfo_url"
            label="Userinfo URL"
            value={@editing_provider.userinfo_url}
          />
          <.input type="text" name="scopes" label="Scopes" value={@editing_provider.scopes} />
          <.input
            type="number"
            name="sort_order"
            label="Sort order"
            value={@editing_provider.sort_order}
          />
          <div class="flex justify-end gap-2">
            <.button type="button" variant="outline" phx-click="cancel_edit_provider">
              Cancel
            </.button>
            <.button type="submit">Save</.button>
          </div>
        </form>
      </.sheet>
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

        <form phx-submit="add_member" class="flex items-end gap-2 [&_>div]:mb-0">
          <div class="flex-1">
            <.input type="email" name="email" label="Add member by email" value="" required />
          </div>
          <div class="space-y-1.5">
            <span class="block font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
              Role
            </span>
            <.select
              id="add-member-role"
              name="role"
              value="member"
              options={Enum.map(@roles, &%{value: &1, label: String.capitalize(&1)})}
            />
          </div>
          <.button type="submit">Add</.button>
        </form>

        <.data_table cols={~w(Email Role) ++ [""]} empty={@members == []}>
          <tr
            :for={{user, role} <- @members}
            class="border-b border-border/60 last:border-0 hover:bg-muted/40"
          >
            <td class="px-3 py-2 font-mono text-xs text-foreground/90">{user.email}</td>
            <td class="px-3 py-2">
              <.select
                id={"member-role-#{user.id}"}
                value={role}
                options={Enum.map(@roles, &%{value: &1, label: String.capitalize(&1)})}
                on_change="update_role"
                params={%{"user_id" => user.id}}
              />
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
  attr :apps, :list, required: true
  attr :audit_filter, :string, required: true
  attr :audit_app_filter, :string, required: true

  defp audit_view(assigns) do
    assigns =
      assign(assigns,
        filtered:
          assigns.events
          |> Enum.filter(&audit_matches?(&1, assigns.audit_filter))
          |> Enum.filter(&audit_app_matches?(&1, assigns.audit_app_filter))
      )

    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between gap-4">
        <p class="font-mono text-xs text-muted-foreground">
          in-memory, capped at 100 events
          <.link patch={~p"/console?view=webhooks"} class="text-primary hover:underline">
            add a webhook for durable retention
          </.link>
        </p>
        <div class="flex shrink-0 items-center gap-2">
          <.select
            id="filter-audit-app"
            value={@audit_app_filter}
            placeholder="all apps"
            options={
              [%{value: "", label: "all apps"}] ++
                Enum.map(@apps, &%{value: &1.slug, label: &1.name})
            }
            on_change="filter_audit_app"
            params={%{}}
          />
          <form phx-change="filter_audit">
            <input
              type="text"
              name="filter"
              value={@audit_filter}
              placeholder="filter events"
              class="h-8 w-48 rounded-md border border-input bg-background px-3 font-mono text-xs placeholder:text-muted-foreground/60"
            />
          </form>
        </div>
      </div>
      <.data_table cols={~w(Event Details At)} empty={@filtered == []}>
        <tr
          :for={e <- @filtered}
          class="border-b border-border/60 last:border-0 hover:bg-muted/40"
        >
          <td class="px-3 py-2 font-mono text-xs text-foreground/90">{e.event}</td>
          <td class="px-3 py-2 break-all font-mono text-xs text-muted-foreground">
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

  defp audit_matches?(event, filter) do
    haystack = String.downcase("#{event.event} #{brief(event.metadata)}")
    String.contains?(haystack, String.downcase(filter))
  end

  defp audit_app_matches?(_event, ""), do: true

  defp audit_app_matches?(event, app_slug),
    do: to_string(event.metadata[:app_slug]) == app_slug

  # ── section: webhooks ─────────────────────────────────────────
  attr :endpoints, :list, required: true
  attr :webhook_filter, :string, default: ""
  attr :events, :list, required: true
  attr :webhook_secret, :string, default: nil
  attr :webhook_endpoint, :map, default: nil

  # Event names are "login:attempt" or "user.registered": the part before the
  # separator is the family the picker groups by.
  defp event_group(%{value: event}), do: event |> String.split(~r/[:.]/) |> hd()

  defp webhooks_view(assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="font-mono text-xs text-muted-foreground">
        signed outbound webhooks · retries 3 times · secret shown once after create or rotate
      </p>

      <div class="rounded-lg border border-border bg-card p-5">
        <div class="flex items-center gap-2 text-sm font-medium">
          <span class="lucide-webhook size-4 block text-primary" /> Add endpoint
        </div>
        <form
          phx-submit="create_webhook"
          class="mt-4 grid gap-3 sm:grid-cols-[1fr_16rem_auto] sm:items-end [&_>div]:mb-0"
        >
          <label class="space-y-1.5">
            <span class="font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
              URL
            </span>
            <.base_input
              type="url"
              name="url"
              placeholder="https://your-service.example/hooks/you"
              required
              class="h-8 font-mono text-xs"
            />
          </label>

          <div class="space-y-1.5">
            <span class="block font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
              Events
            </span>
            <.multi_select
              id="webhook-events"
              name="events"
              options={Enum.map(@events, &%{value: &1, label: &1})}
              group_by={&event_group/1}
              placeholder="select events"
              unit="events"
            />
          </div>

          <.button type="submit">Create endpoint</.button>
        </form>
      </div>

      <.list_search
        event="filter_webhooks"
        value={@webhook_filter}
        placeholder="Search endpoints by URL"
        count={length(@endpoints)}
        noun="shown"
      />

      <.data_table cols={~w(URL Events Status Created) ++ [""]} empty={@endpoints == []}>
        <tr
          :for={endpoint <- @endpoints}
          class="border-b border-border/60 transition-colors last:border-0 hover:bg-muted/40"
        >
          <td class="max-w-[16rem] truncate px-3 py-2 font-mono text-xs text-foreground/90">
            {endpoint.url}
          </td>
          <td class="px-3 py-2">
            <div class="flex max-w-xs flex-wrap gap-1">
              <span
                :for={event <- endpoint.events}
                class="rounded bg-muted px-1.5 py-0.5 font-mono text-[11px] text-muted-foreground"
              >
                {event}
              </span>
            </div>
          </td>
          <td class="px-3 py-2">
            <.switch
              checked={endpoint.enabled}
              label={if endpoint.enabled, do: "enabled", else: "disabled"}
              phx-click="toggle_webhook"
              phx-value-id={endpoint.id}
            />
          </td>
          <td class="px-3 py-2 text-right font-mono text-xs tabular-nums text-muted-foreground">
            {Calendar.strftime(endpoint.inserted_at, "%Y-%m-%d")}
          </td>
          <td class="px-3 py-2 text-right">
            <div class="flex items-center justify-end gap-1">
              <button
                type="button"
                phx-click="rotate_webhook_secret"
                phx-value-id={endpoint.id}
                data-confirm="Rotate the signing secret? Deliveries signed with the old secret will fail verification."
                class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              >
                Rotate secret
              </button>
              <button
                type="button"
                phx-click="delete_webhook"
                phx-value-id={endpoint.id}
                data-confirm={"Delete endpoint #{endpoint.url}?"}
                class="rounded px-2 py-1 text-xs text-muted-foreground transition-colors hover:bg-destructive hover:text-destructive-foreground"
              >
                Delete
              </button>
            </div>
          </td>
        </tr>
      </.data_table>

      <.dialog
        id="webhook-secret"
        open={@webhook_secret != nil}
        on_close="dismiss_webhook_secret"
      >
        <:title>Signing secret</:title>
        <:description>
          Copy this now. Deliveries are signed with it and it is never shown again.
        </:description>
        <div :if={@webhook_secret} class="space-y-3">
          <div class="rounded-md border border-border bg-background px-3 py-2 font-mono text-xs break-all text-primary">
            {@webhook_secret}
          </div>
          <div class="flex items-center justify-between">
            <span :if={@webhook_endpoint} class="font-mono text-xs text-muted-foreground">
              {@webhook_endpoint.url}
            </span>
            <.copy_button id="copy-webhook-secret" value={@webhook_secret} label="Copy secret" />
          </div>
        </div>
        <:footer>
          <.button variant="outline" phx-click="dismiss_webhook_secret">Done</.button>
        </:footer>
      </.dialog>
    </div>
    """
  end

  attr :event, :string, required: true
  attr :value, :string, required: true
  attr :placeholder, :string, required: true
  attr :count, :integer, required: true
  attr :noun, :string, required: true

  defp list_search(assigns) do
    ~H"""
    <form phx-change={@event} class="flex items-center gap-2 [&_>div]:mb-0">
      <div class="flex-1">
        <.input
          type="text"
          name="query"
          value={@value}
          placeholder={@placeholder}
          phx-debounce="200"
        />
      </div>
      <span class="shrink-0 font-mono text-xs text-muted-foreground">
        {@count} {@noun}
      </span>
    </form>
    """
  end

  attr :preset, :string, required: true
  attr :base_url, :string, required: true

  defp provider_setup(assigns) do
    assigns = assign(assigns, guide: IdentityProviders.Setup.for_preset(assigns.preset))

    ~H"""
    <.disclosure
      :if={@guide}
      id={"provider-setup-#{@preset}"}
      summary={"Where to get these credentials for #{String.capitalize(@preset)}"}
    >
      <ol class="list-decimal space-y-1.5 pl-5 text-sm text-muted-foreground">
        <li :for={step <- @guide.steps}>{step}</li>
      </ol>

      <dl class="mt-3 space-y-1.5 border-t border-border pt-3 text-xs">
        <div class="flex gap-2">
          <dt class="shrink-0 text-muted-foreground">Callback URL</dt>
          <dd class="min-w-0 flex-1 text-right">
            <span class="font-mono break-all text-primary">
              {@base_url}/auth/{@preset}/callback
            </span>
            <span class="mt-0.5 block text-muted-foreground">
              paste into “{@guide.redirect_field}”
            </span>
          </dd>
        </div>
        <div class="flex justify-between gap-2">
          <dt class="shrink-0 text-muted-foreground">Scopes</dt>
          <dd class="text-right">{@guide.scopes}</dd>
        </div>
      </dl>

      <p class="mt-3 rounded-md border border-signal-warn/40 bg-signal-warn/10 px-3 py-2 text-xs">
        {@guide.caveat}
      </p>

      <p class="mt-2 text-[11px] text-muted-foreground">
        From
        <.link href={@guide.source} target="_blank" class="underline underline-offset-2">
          {URI.parse(@guide.source).host}
        </.link>
        — vendor consoles change, so check there if a step no longer matches.
      </p>
    </.disclosure>
    """
  end

  # ── section: features ─────────────────────────────────────────
  attr :features, :map, required: true
  attr :onboarding, :boolean, required: true

  defp features_view(assigns) do
    assigns = assign(assigns, copy: @feature_copy, mandatory: @mandatory_features)

    ~H"""
    <div class="max-w-2xl space-y-5">
      <div :if={@onboarding} class="rounded-lg border border-border bg-muted/40 p-4 text-sm">
        <p class="font-medium">Welcome. Choose what this instance offers.</p>
        <p class="mt-1 text-muted-foreground">
          You ships a lot of surface. Switch off what you are not using and it
          disappears from the console and the login page. You can change this later.
        </p>
      </div>

      <form id="features-form" phx-submit="save_features" class="space-y-5">
        <div class="rounded-lg border border-border bg-card p-5">
          <div class="mb-3 text-sm font-medium">Optional</div>
          <div class="space-y-3">
            <label :for={{key, value} <- @features} class="flex items-start gap-3">
              <%!-- Paired hidden input so an unticked box submits "false"
                    rather than vanishing from the params. --%>
              <input type="hidden" name={"features[#{key}]"} value="false" />
              <input
                type="checkbox"
                name={"features[#{key}]"}
                value="true"
                checked={value}
                class="mt-0.5 size-4 rounded border-border"
              />
              <span>
                <span class="block text-sm">{elem(Map.fetch!(@copy, key), 0)}</span>
                <span class="block text-xs text-muted-foreground">
                  {elem(Map.fetch!(@copy, key), 1)}
                </span>
              </span>
            </label>
          </div>
        </div>

        <div class="rounded-lg border border-border bg-card p-5">
          <div class="mb-1 text-sm font-medium">Always on</div>
          <p class="mb-3 text-xs text-muted-foreground">
            Listed so you can see they exist. These cannot be switched off.
          </p>
          <div class="space-y-3">
            <label :for={{label, description} <- @mandatory} class="flex items-start gap-3 opacity-60">
              <input type="checkbox" checked disabled class="mt-0.5 size-4 rounded border-border" />
              <span>
                <span class="block text-sm">{label}</span>
                <span class="block text-xs text-muted-foreground">{description}</span>
              </span>
            </label>
          </div>
        </div>

        <div class="flex justify-end">
          <.button type="submit">Save</.button>
        </div>
      </form>
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
          <.setting_field
            name="session_expiry_hours"
            label="Session expiry (hours)"
            value={@settings[:session_expiry_hours]}
          />
          <.setting_field
            name="jwt_expiry_hours"
            label="JWT expiry (hours)"
            value={@settings[:jwt_expiry_hours]}
          />
          <.setting_field
            name="code_expiry_minutes"
            label="Auth code expiry (minutes)"
            value={@settings[:code_expiry_minutes]}
          />
          <.setting_field
            name="magic_link_expiry_minutes"
            label="Magic link expiry (minutes)"
            value={@settings[:magic_link_expiry_minutes]}
          />
        </.settings_group>

        <.settings_group title="Erlang distribution">
          <.setting_field
            name="erlang_node_name"
            label="Node name"
            value={@settings[:erlang_node_name]}
          />
          <.setting_field name="epmd_port" label="EPMD port" value={@settings[:epmd_port]} />
          <.secret_setting_field
            name="erlang_cookie"
            label="Cookie"
            value={@settings[:erlang_cookie]}
          />
        </.settings_group>

        <.settings_group title="Provisioning & audit">
          <.secret_setting_field
            name="scim_bearer_token"
            label="SCIM bearer token"
            value={@settings[:scim_bearer_token]}
          />
          <.setting_field
            name="audit_webhook_url"
            label="Audit webhook URL"
            value={@settings[:audit_webhook_url]}
          />
          <p class="pt-1 font-mono text-[11px] text-muted-foreground">
            SCIM base: {@base_url}/scim/v2 · secrets are write-only, use clear to disable
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
      <.base_input
        type={@type}
        name={@name}
        value={@value}
        class="h-8 max-w-[16rem] font-mono text-xs"
      />
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil

  defp secret_setting_field(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-4 text-sm">
      <span class="text-muted-foreground">{@label}</span>
      <div class="flex items-center gap-2">
        <span class="font-mono text-[11px] text-muted-foreground">
          {if @value in [nil, ""], do: "not set", else: "••••••••"}
        </span>
        <.base_input
          type="password"
          name={@name}
          value=""
          placeholder="new value"
          autocomplete="off"
          class="h-8 max-w-[12rem] font-mono text-xs"
        />
        <button
          :if={@value not in [nil, ""]}
          type="button"
          phx-click="clear_setting"
          phx-value-key={@name}
          data-confirm={"Clear #{@label}? This takes effect immediately."}
          class="font-mono text-[11px] text-signal-down hover:underline"
        >
          clear
        </button>
      </div>
    </div>
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
