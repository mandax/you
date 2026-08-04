defmodule YouWeb.ConsoleLive do
  @moduledoc """
  Admin console at `/console`.

  A single LiveView shell (sidebar + topbar + section views) with a dense,
  mono-accented design: cards and tables, a live
  connection indicator, and `?view=` navigation. Every section is wired to the
  real domain (`You.Admin`, `You.Settings`,
  `You.Audit.Streamer`). No fabricated data.
  """
  use YouWeb, :live_view

  import YouWeb.Components.ConsoleChrome

  alias You.{Admin, Accounts, Settings, Webhooks, Roles, IdentityProviders}
  alias You.Audit.Streamer
  alias You.Config.{Bundle, Vault}

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
    "audit" =>
      "Privileged actions, newest first. This is the live in-memory view; configure the audit webhook for retention.",
    "webhooks" =>
      "Signed outbound events. Use them to react to identity changes in your own systems.",
    "emails" =>
      "The transactional mail You sends. A template you have not edited keeps using the default copy, so it still improves with You.",
    "features" =>
      "What this instance offers. Switching something off removes it from the console and the login page.",
    "settings" =>
      "Instance-wide tuning: token lifetimes, Erlang distribution, and integration secrets.",
    "backup" =>
      "Export an encrypted snapshot of this instance's settings, apps, providers and webhooks — or restore one. Never a database backup: no users, tokens or sessions."
  }

  @feature_copy %{
    feature_passkeys: {"Passkeys", "WebAuthn sign-in and per-user passkey management."},
    feature_magic_link: {"Magic links", "Passwordless sign-in by emailed link."},
    feature_social_login: {"Social sign-in", "Upstream identity providers on the login page."},
    feature_webhooks: {"Webhooks", "Signed outbound events."},
    feature_guest_login:
      {"Guest accounts",
       "Anonymous accounts a first-party app can create before signup, upgraded in place when the person signs up. Off by default: it mints user rows on request."},
    feature_landing_page:
      {"Public landing page",
       "What visitors see at /. Switched off, / goes to the console for admins and to the login page for everyone else — the right shape when this instance is infrastructure for your own app rather than a product with a homepage."}
  }

  # Write-only in the console: never rendered into the DOM, blank on save
  # keeps the current value, cleared via the explicit "clear" button.
  @secret_settings [:erlang_cookie, :scim_bearer_token, :smtp_password, :api_token]

  @settings_fields [
    %{key: :session_expiry_hours, label: "Session expiry (hours)"},
    %{key: :jwt_expiry_hours, label: "JWT expiry (hours)"},
    %{key: :code_expiry_minutes, label: "Auth code expiry (minutes)"},
    %{key: :magic_link_expiry_minutes, label: "Magic link expiry (minutes)"},
    %{key: :erlang_node_name, label: "Erlang node name"},
    %{key: :epmd_port, label: "EPMD port"},
    %{key: :erlang_cookie, label: "Erlang cookie"},
    %{key: :scim_bearer_token, label: "SCIM bearer token"},
    %{key: :audit_webhook_url, label: "Audit webhook URL"},
    %{key: :you_mode, label: "Deployment mode"},
    %{key: :smtp_host, label: "SMTP host"},
    %{key: :smtp_port, label: "SMTP port"},
    %{key: :smtp_username, label: "SMTP username"},
    %{key: :smtp_password, label: "SMTP password"},
    %{key: :mail_from, label: "Mail from address"},
    %{key: :api_token, label: "Management API token"},
    %{key: :analytics_src, label: "Analytics script URL"},
    %{key: :analytics_domain, label: "Analytics domain"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, self(), :refresh)

    {:ok,
     socket
     |> allow_upload(:bundle,
       accept: ~w(.you-bundle .json),
       max_entries: 1,
       max_file_size: 25_000_000,
       progress: &handle_bundle_progress/3
     )
     |> assign(
       page_title: "Console",
       nav: nav(),
       view: "overview",
       node_name: Node.self(),
       new_secret: nil,
       secret_app: nil,
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
       oidc_providers: IdentityProviders.list_providers() |> Enum.map(& &1.slug) |> Enum.sort(),
       saved: false,
       app_filter: "",
       provider_filter: "",
       webhook_filter: "",
       email_overrides: %{},
       features: Settings.features() |> Map.new(&{&1, Settings.get(&1)}),
       onboarding: not Settings.get(:onboarding_completed),
       single_mode: You.Mode.single?(),
       mail_ready: You.Mailer.production_ready?(),
       trigger_export: false,
       import_ciphertext: nil,
       import_payload: nil,
       import_preview: nil,
       import_error: nil
     )}
  end

  @doc """
  Resolves `?view=` and loads exactly the data that view renders.

  `handle_params/3` runs after `mount/3` on every render — disconnected and
  connected alike — so this is the one place a view's dataset needs loading;
  nothing is preloaded in `mount/3` that might not match the view a
  redirect or deep link actually lands on.
  """
  @impl true
  def handle_params(params, _uri, socket) do
    # First admin login lands here rather than on an overview of a console
    # they have not shaped yet.
    default = if socket.assigns.onboarding, do: "features", else: "overview"
    view = params["view"] || default
    view = if view in section_ids(), do: view, else: default
    {:noreply, socket |> assign(view: view, saved: false) |> load_view(view)}
  end

  @doc """
  The 5-second live tick. Only the overview and audit views render the audit
  feed, so this is the only thing worth re-querying on a timer — users, apps,
  providers and role assignments do not change on their own between admin
  actions, and reloading them here would repeat the wholesale re-read this
  module used to do per connected admin, per tick.
  """
  @impl true
  def handle_info(:refresh, socket) do
    if socket.assigns.view in ["overview", "audit"] do
      {:noreply, load_events(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── users ─────────────────────────────────────────────────────
  @impl true
  def handle_event("logout_user", %{"id" => id}, socket) do
    user = Admin.get_user!(id)
    Accounts.delete_all_user_tokens(user)
    audit_admin(socket, "logout_user", user.email)

    {:noreply,
     socket |> load_users() |> put_flash(:info, "All sessions revoked for #{user.email}.")}
  end

  def handle_event("anonymize_user", %{"id" => id}, socket) do
    user = Admin.get_user!(id)
    {:ok, _} = Accounts.anonymize_user(user)
    audit_admin(socket, "anonymize_user", user.email)
    {:noreply, socket |> load_users() |> put_flash(:info, "User anonymized.")}
  end

  # Also revokes every session: a second factor is reset either because a
  # user lost the device that proves it, or because an account may be
  # compromised and support cannot tell which from here. Either way, a
  # session that was live under the old, stronger guarantee should not
  # keep riding it silently once that guarantee is gone — the user signs
  # back in with their password and, if they choose, re-enrolls.
  def handle_event("reset_2fa", %{"id" => id}, socket) do
    user = Admin.get_user!(id)
    {:ok, _} = Accounts.disable_totp(user)
    Accounts.delete_all_user_tokens(user)
    audit_admin(socket, "reset_2fa", user.email)

    {:noreply,
     socket
     |> load_users()
     |> refresh_editing_user(id)
     |> put_flash(:info, "Two-factor authentication reset for #{user.email}.")}
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
        {:noreply, socket |> load_apps() |> assign(new_secret: secret, secret_app: app)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create app: #{error_summary(changeset)}")}
    end
  end

  def handle_event("delete_app", %{"id" => id}, socket) do
    # `Admin.delete_app/1` emits the audit event itself; a second one here
    # would record the same removal twice under two different shapes.
    case id |> Admin.get_app!() |> Admin.delete_app() do
      {:ok, _app} ->
        {:noreply, socket |> load_apps() |> put_flash(:info, "App deleted.")}

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
         |> load_providers()
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
         |> load_providers()
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

    {:noreply, load_providers(socket)}
  end

  def handle_event("delete_provider", %{"id" => id}, socket) do
    provider = IdentityProviders.get_provider!(id)
    {:ok, _} = IdentityProviders.delete_provider(provider)
    audit_admin(socket, "delete_provider", provider.slug)
    {:noreply, socket |> load_providers() |> put_flash(:info, "Provider deleted.")}
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
          load_users(socket)

        role == "user" and user.is_admin ->
          Admin.demote_admin(user)
          audit_admin(socket, "demote_admin", user.email)
          load_users(socket)

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
        {:noreply, socket |> load_assignments() |> refresh_editing_user(params["user_id"])}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Role is not allowed for this app.")}
    end
  end

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, new_secret: nil, secret_app: nil)}

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
         |> load_endpoints()
         |> assign(webhook_secret: endpoint.secret, webhook_endpoint: endpoint)}

      {:error, changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not create endpoint: #{error_summary(changeset)}")}
    end
  end

  def handle_event("toggle_webhook", %{"id" => id}, socket) do
    endpoint = Webhooks.get_endpoint!(id)
    {:ok, _} = Webhooks.update_endpoint(endpoint, %{"enabled" => !endpoint.enabled})
    {:noreply, load_endpoints(socket)}
  end

  def handle_event("rotate_webhook_secret", %{"id" => id}, socket) do
    endpoint = Webhooks.get_endpoint!(id)
    {:ok, rotated} = Webhooks.rotate_secret(endpoint)
    audit_admin(socket, "rotate_webhook_secret", endpoint.url)

    {:noreply,
     socket
     |> load_endpoints()
     |> assign(webhook_secret: rotated.secret, webhook_endpoint: rotated)}
  end

  def handle_event("delete_webhook", %{"id" => id}, socket) do
    endpoint = Webhooks.get_endpoint!(id)
    {:ok, _} = Webhooks.delete_endpoint(endpoint)
    audit_admin(socket, "delete_webhook", endpoint.url)
    {:noreply, socket |> load_endpoints() |> put_flash(:info, "Endpoint deleted.")}
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

  # ── emails ────────────────────────────────────────────────────
  def handle_event("save_email_template", %{"key" => key} = params, socket) do
    case You.EmailTemplates.upsert(key, Map.take(params, ["subject", "body"])) do
      {:ok, _template} ->
        audit_admin(socket, "update_email_template", key)

        {:noreply,
         socket |> load_email_templates() |> put_flash(:info, "Email template updated.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, error_summary(changeset))}

      {:error, :unknown_template} ->
        {:noreply, put_flash(socket, :error, "No such email template.")}
    end
  end

  def handle_event("reset_email_template", %{"key" => key}, socket) do
    :ok = You.EmailTemplates.reset(key)
    audit_admin(socket, "reset_email_template", key)

    {:noreply,
     socket |> load_email_templates() |> put_flash(:info, "Email template reset to default.")}
  end

  def handle_event("save_settings", params, socket) do
    changed =
      Enum.flat_map(@settings_fields, fn %{key: key} ->
        raw = params[Atom.to_string(key)]

        if is_binary(raw) and not (key in @secret_settings and raw == "") do
          value = parse_value(key, raw)
          previous = Settings.get(key)
          Settings.set(key, value)

          if previous == value, do: [], else: [key]
        else
          []
        end
      end)

    audit_settings(socket, changed)

    You.Accounts.CookieSync.apply_cookie()
    You.Audit.Streamer.reload()
    You.Mode.invalidate_app_cache()

    {:noreply,
     socket
     |> load_settings()
     |> assign(
       saved: true,
       single_mode: You.Mode.single?(),
       nav: nav(),
       mail_ready: You.Mailer.production_ready?()
     )}
  end

  def handle_event("clear_setting", %{"key" => key}, socket) do
    # Resolve against the allowlist rather than converting first: an unknown key
    # would raise in `String.to_existing_atom/1` before any membership check.
    case Enum.find(@secret_settings, &(Atom.to_string(&1) == key)) do
      nil ->
        {:noreply, socket}

      setting ->
        Settings.set(setting, "")
        audit_settings(socket, [setting])
        You.Accounts.CookieSync.apply_cookie()
        You.Audit.Streamer.reload()
        {:noreply, load_settings(socket)}
    end
  end

  # ── backup ────────────────────────────────────────────────────
  #
  # Export is a controller download, not a LiveView event: `handle_event`
  # cannot stream a file. The form in `backup_view/1` posts straight to
  # `YouWeb.ConsoleBackupController` — this event only checks the two
  # password fields agree and are long enough, then flips
  # `phx-trigger-action` so the browser submits that form natively, carrying
  # the password field's live DOM value with it. Neither password is kept
  # past this check — `params` is discarded either way.
  def handle_event(
        "prepare_export",
        %{"password" => password, "password_confirmation" => confirmation},
        socket
      ) do
    cond do
      String.length(password) < Vault.min_password_length() ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The export password must be at least #{Vault.min_password_length()} characters."
         )}

      password != confirmation ->
        {:noreply, put_flash(socket, :error, "Passwords do not match.")}

      true ->
        {:noreply, assign(socket, trigger_export: true)}
    end
  end

  def handle_event("prepare_export", _params, socket) do
    {:noreply, put_flash(socket, :error, "Enter and confirm a password to export a bundle.")}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :bundle, ref)}
  end

  # `live_file_input/1` needs the enclosing form to declare `phx-change` to
  # track upload progress; there is nothing else on this form to validate.
  def handle_event("validate_import", _params, socket), do: {:noreply, socket}

  def handle_event("preview_import", %{"password" => password}, socket) do
    case socket.assigns.import_ciphertext do
      nil ->
        {:noreply, put_flash(socket, :error, "Choose a bundle file first.")}

      ciphertext ->
        with {:ok, payload} <- Vault.open(ciphertext, password),
             {:ok, summary} <- Bundle.preview(payload) do
          {:noreply,
           assign(socket, import_payload: payload, import_preview: summary, import_error: nil)}
        else
          {:error, reason} ->
            {:noreply,
             assign(socket, import_payload: nil, import_preview: nil, import_error: reason)}
        end
    end
  end

  def handle_event("apply_import", _params, socket) do
    case socket.assigns.import_payload && Bundle.import(socket.assigns.import_payload) do
      {:ok, summary} ->
        audit_admin(socket, "import_config_bundle", import_target(summary))

        {:noreply,
         socket
         |> reset_import()
         |> put_flash(:info, "Bundle imported: #{import_target(summary)}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Import failed: #{import_error_copy(reason)}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Preview a bundle before applying it.")}
    end
  end

  def handle_event("cancel_import", _params, socket), do: {:noreply, reset_import(socket)}

  # Consumes the file as soon as the upload itself completes, rather than
  # later in `preview_import`: `allow_upload/3`'s `:progress` callback runs
  # synchronously in the same message that reports 100%, which is the
  # documented place to call `consume_uploaded_entry/3`. Consuming at preview
  # time instead would tie the temp file's lifetime to a password the
  # operator hasn't typed yet, and a wrong password would force a re-upload.
  defp handle_bundle_progress(:bundle, entry, socket) do
    if entry.done? do
      contents =
        consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read!(path)} end)

      {:noreply, assign(socket, import_ciphertext: contents)}
    else
      {:noreply, socket}
    end
  end

  defp reset_import(socket) do
    assign(socket,
      import_ciphertext: nil,
      import_payload: nil,
      import_preview: nil,
      import_error: nil
    )
  end

  defp import_target(summary) do
    Enum.map_join(summary, ", ", fn {section, count} -> "#{count} #{section}" end)
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

  # Which keys changed, never their values: the settings screen holds the
  # Erlang cookie, the SCIM token and the SMTP password, and an audit trail
  # that copies them is a second place to steal them from. Repointing
  # `audit_webhook_url` is itself recorded, so silencing the trail cannot be
  # done silently.
  defp audit_settings(_socket, []), do: :ok

  defp audit_settings(socket, keys) do
    audit_admin(socket, "update_settings", keys |> Enum.map(&to_string/1) |> Enum.join(", "))
  end

  defp audit_admin(socket, action, target) do
    :telemetry.execute([:you, :audit, :admin, :action], %{}, %{
      admin_user_id: socket.assigns.current_scope.user.id,
      action: action,
      target: target
    })
  end

  # Loads exactly the data `view` renders — nothing more.
  #
  # Each section carries its own rows: `users` needs the roster, the app list
  # (for its filter and the per-app role sheet) and the role-assignment map;
  # `apps`/`providers`/`webhooks` need only their own table; `overview` needs
  # counts, not rows, since it only ever prints a number; `audit` needs the
  # live event feed plus the app list for its filter dropdown; `features` and
  # `settings` carry their own state already (feature flags at mount,
  # instance settings via `load_settings/1`) so there is nothing to fetch here.
  defp load_view(socket, "overview"), do: socket |> load_counts() |> load_events()

  defp load_view(socket, "users"),
    do: socket |> load_users() |> load_apps() |> load_assignments()

  defp load_view(socket, "apps"), do: load_apps(socket)
  defp load_view(socket, "providers"), do: load_providers(socket)
  defp load_view(socket, "audit"), do: socket |> load_events() |> load_apps()
  defp load_view(socket, "webhooks"), do: load_endpoints(socket)
  defp load_view(socket, "emails"), do: load_email_templates(socket)
  defp load_view(socket, "features"), do: socket
  defp load_view(socket, "settings"), do: load_settings(socket)
  defp load_view(socket, "backup"), do: socket
  defp load_view(socket, _view), do: socket

  # Instance-wide counts for the overview cards. `Repo.aggregate/2` rather
  # than loading every row and taking `length/1`, since the UI only ever
  # prints the number.
  defp load_counts(socket) do
    assign(socket,
      user_count: Admin.count_users(),
      admin_count: Admin.count_admins(),
      app_count: Admin.count_apps()
    )
  end

  defp load_users(socket), do: assign(socket, users: Admin.list_users_with_stats())
  defp load_apps(socket), do: assign(socket, apps: Admin.list_apps())
  defp load_assignments(socket), do: assign(socket, assignments: Roles.all_assignments())
  defp load_providers(socket), do: assign(socket, providers: IdentityProviders.list_providers())
  defp load_endpoints(socket), do: assign(socket, endpoints: Webhooks.list_endpoints())
  defp load_events(socket), do: assign(socket, events: Streamer.recent())

  defp load_email_templates(socket),
    do: assign(socket, email_overrides: You.EmailTemplates.overrides())

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

  defp parse_value(:you_mode, "single"), do: "single"
  defp parse_value(:you_mode, _raw), do: "multi"

  defp parse_value(_key, raw) do
    if raw =~ ~r/^\d+$/, do: String.to_integer(raw), else: raw
  end

  @single_section_copy %{
    "users" =>
      "Everyone with an account here. Filter by role or status, and manage a user's access from their row."
  }

  defp section_copy(view, true),
    do: Map.get(@single_section_copy, view) || Map.get(@section_copy, view)

  defp section_copy(view, false), do: Map.get(@section_copy, view)

  defp nav_label(view), do: Enum.find_value(nav(), "", &if(&1.id == view, do: &1.label))

  # ── shell ─────────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    ~H"""
    <.console_shell nav={@nav} active={@view} title={nav_label(@view)} node_name={@node_name}>
      <div class="mb-5">
        <h1 class="text-lg font-medium">{nav_label(@view)}</h1>
        <p
          :if={section_copy(@view, @single_mode)}
          class="mt-1 max-w-2xl text-sm text-muted-foreground"
        >
          {section_copy(@view, @single_mode)}
        </p>
      </div>

      <%= case @view do %>
        <% "overview" -> %>
          <.overview
            user_count={@user_count}
            admin_count={@admin_count}
            app_count={@app_count}
            events={@events}
            single_mode={@single_mode}
            mail_ready={@mail_ready}
          />
        <% "users" -> %>
          <.users_view
            users={@users}
            apps={@apps}
            assignments={@assignments}
            filters={@user_filters}
            current_scope={@current_scope}
            editing_user={@editing_user}
            single_mode={@single_mode}
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
        <% "audit" -> %>
          <.audit_view
            events={@events}
            apps={@apps}
            audit_filter={@audit_filter}
            audit_app_filter={@audit_app_filter}
            single_mode={@single_mode}
          />
        <% "webhooks" -> %>
          <.webhooks_view
            endpoints={search(@endpoints, @webhook_filter, [:url])}
            webhook_filter={@webhook_filter}
            events={Webhooks.events()}
            webhook_secret={@webhook_secret}
            webhook_endpoint={@webhook_endpoint}
          />
        <% "emails" -> %>
          <.emails_view overrides={@email_overrides} />
        <% "features" -> %>
          <.features_view features={@features} onboarding={@onboarding} />
        <% "settings" -> %>
          <.settings_view
            settings={@settings}
            base_url={@base_url}
            oidc_providers={@oidc_providers}
            saved={@saved}
          />
        <% "backup" -> %>
          <.backup_view
            uploads={@uploads}
            trigger_export={@trigger_export}
            import_preview={@import_preview}
            import_error={@import_error}
            has_ciphertext={@import_ciphertext != nil}
          />
      <% end %>

      <Layouts.flash_group flash={@flash} />
    </.console_shell>
    """
  end

  # ── section: overview ─────────────────────────────────────────
  attr :user_count, :integer, required: true
  attr :admin_count, :integer, required: true
  attr :app_count, :integer, required: true
  attr :events, :list, required: true
  attr :single_mode, :boolean, default: false
  attr :mail_ready, :boolean, default: true

  defp overview(assigns) do
    ~H"""
    <div class="space-y-6">
      <div
        :if={!@mail_ready}
        class="rounded-lg border border-signal-warn/40 bg-signal-warn/5 p-4 text-sm"
      >
        <div class="flex items-center gap-2 font-medium">
          <span class="lucide-triangle-alert size-4 block text-signal-warn" /> Email is not configured
        </div>
        <p class="mt-1 text-muted-foreground">
          Mail is being kept in an in-memory mailbox instead of being delivered. Magic links, email
          2FA, address confirmation and password resets will not reach users. Configure SMTP from
          the Settings section, or read the queued mail at
          <.link href={~p"/console/mailbox"} class="text-primary underline">
            /console/mailbox
          </.link>
          while evaluating.
        </p>
      </div>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <.metric_card label="Users" value={to_string(@user_count)} />
        <.metric_card label="Admins" value={to_string(@admin_count)} />
        <.metric_card :if={!@single_mode} label="Apps" value={to_string(@app_count)} />
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
  attr :single_mode, :boolean, default: false

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
            :if={!@single_mode}
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
            <.access_summary access={access_summary(@assignments, @apps, row.user.id, @single_mode)} />
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
          {if @single_mode,
            do: "Roles on You and on this application.",
            else: "Roles on You and on each app."} Changes apply immediately.
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

          <%!-- Single mode has one app, so naming it on every row repeats what
                the heading already said; the row is labelled by what it sets. --%>
          <section class="space-y-2">
            <h3 class="font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
              {if @single_mode, do: "Application", else: "Apps"}
            </h3>
            <div
              :for={app <- @apps}
              class="flex items-center justify-between gap-4 border-b border-border/50 py-1.5 last:border-0"
            >
              <span class="min-w-0 truncate text-sm">
                {if @single_mode, do: "Role", else: app.name}
              </span>
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

          <section class="space-y-2">
            <h3 class="font-mono text-[10px] uppercase tracking-widest text-muted-foreground">
              Security
            </h3>
            <div class="flex items-center justify-between gap-4">
              <div class="text-sm">
                <span>Two-factor authentication</span>
                <span class="ml-2 text-xs text-muted-foreground">
                  {if @editing_user.totp_enabled, do: "enabled", else: "not enabled"}
                </span>
              </div>
              <button
                :if={@editing_user.totp_enabled}
                type="button"
                phx-click="reset_2fa"
                phx-value-id={@editing_user.id}
                data-confirm={"Reset two-factor authentication for #{@editing_user.email}? " <>
                  "This disables their authenticator app, deletes their recovery codes, and " <>
                  "signs out every session. They will be able to sign in with their password " <>
                  "alone until they re-enroll."}
                class="text-sm text-destructive hover:underline whitespace-nowrap"
              >
                Reset 2FA
              </button>
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
  #
  # In single mode there is one app, so the app name is the same word on every
  # row and the count can only ever be zero: the cell is just the role.
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
          title={if app, do: "#{role} on #{app}", else: role}
        >
          {if app, do: "#{role}·#{app}", else: role}
        </span>
      </div>
      <span :if={@access.rest > 0} class="shrink-0 font-mono text-[11px] text-muted-foreground">
        +{@access.rest} {if @access.rest == 1, do: "app", else: "apps"}
      </span>
    </div>
    """
  end

  @elevated_shown 2

  defp access_summary(assignments, apps, user_id, single_mode) do
    roles = Map.get(assignments, user_id, %{})
    names = Map.new(apps, &{&1.id, &1.name})

    elevated =
      for {app_id, role} <- roles,
          role != "user",
          Map.has_key?(names, app_id),
          do: {role, if(single_mode, do: nil, else: names[app_id])}

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

  # ── section: audit ────────────────────────────────────────────
  attr :events, :list, required: true
  attr :apps, :list, required: true
  attr :audit_filter, :string, required: true
  attr :audit_app_filter, :string, required: true
  attr :single_mode, :boolean, default: false

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
            :if={!@single_mode}
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

  defp audit_app_matches?(event, app_slug) do
    to_string(event.metadata[:app_slug]) == app_slug or legacy_role_event?(event, app_slug)
  end

  # `set_role`/`set_roles` emitted target: "app_slug" or "app_slug:user@email"
  # before app_slug joined the metadata, so filtering by app would drop every
  # historic role event. Recover the slug from the target prefix — but only for
  # those two actions, since any other event whose target happened to equal a
  # slug would otherwise be swept in.
  defp legacy_role_event?(%{metadata: %{action: action, target: target}}, app_slug)
       when action in ["set_role", "set_roles"] and is_binary(target) do
    target == app_slug or String.starts_with?(target, app_slug <> ":")
  end

  defp legacy_role_event?(_event, _app_slug), do: false

  # ── section: emails ───────────────────────────────────────────
  #
  # One form per template, each showing the current copy — the override if
  # there is one, otherwise the default. Saving stores an override; "Reset to
  # default" deletes it, so the template goes back to tracking You's wording
  # rather than freezing today's.
  attr :overrides, :map, required: true

  defp emails_view(assigns) do
    ~H"""
    <div class="space-y-6">
      <div
        :for={definition <- You.EmailTemplates.definitions()}
        class="rounded-lg border border-border"
      >
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-border bg-muted/30 px-4 py-3">
          <div>
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">{definition.label}</span>
              <span
                :if={!Map.has_key?(@overrides, definition.key)}
                class="rounded-full bg-muted px-2 py-0.5 font-mono text-[11px] text-muted-foreground"
              >
                default
              </span>
            </div>
            <p class="mt-0.5 text-xs text-muted-foreground">{definition.description}</p>
          </div>
          <button
            :if={Map.has_key?(@overrides, definition.key)}
            type="button"
            phx-click="reset_email_template"
            phx-value-key={definition.key}
            data-confirm={"Reset the #{definition.label} email to You's default copy?"}
            class="text-xs text-muted-foreground hover:text-destructive"
          >
            Reset to default
          </button>
        </div>

        <form
          id={"email-template-#{definition.key}"}
          phx-submit="save_email_template"
          class="space-y-4 px-4 py-4"
        >
          <input type="hidden" name="key" value={definition.key} />
          <.input
            type="text"
            name="subject"
            label="Subject"
            value={template_value(@overrides, definition, :subject)}
          />
          <.input
            type="textarea"
            name="body"
            label="Body"
            rows="12"
            value={template_value(@overrides, definition, :body)}
          />
          <div class="flex flex-wrap items-center justify-between gap-3">
            <p class="font-mono text-xs text-muted-foreground">
              {Enum.map_join(definition.variables, " ", &"{{#{&1}}}")}
              <span :if={definition.required != []} class="text-foreground/70">
                — {Enum.map_join(definition.required, ", ", &"{{#{&1}}}")} required
              </span>
            </p>
            <.button type="submit">Save</.button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp template_value(overrides, definition, field) do
    case overrides[definition.key] do
      nil -> Map.fetch!(definition, field)
      override -> Map.fetch!(override, field)
    end
  end

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
          <p class="text-xs text-muted-foreground">
            Defaults for every app. An app can pin its own JWT and auth-code lifetimes on its
            page; session expiry is the You cookie itself, so it stays instance-wide.
          </p>
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

        <.settings_group title="Deployment mode">
          <label class="flex items-center justify-between gap-4 text-sm">
            <span class="text-muted-foreground">Mode</span>
            <select
              name="you_mode"
              class="h-8 rounded-md border border-input bg-background px-2 font-mono text-xs"
            >
              <option value="multi" selected={@settings[:you_mode] != "single"}>multi</option>
              <option value="single" selected={@settings[:you_mode] == "single"}>single</option>
            </select>
          </label>
          <p class="pt-1 font-mono text-[11px] text-muted-foreground">
            Single mode replaces the apps registry with one application. Applies to this console
            session on save; other open console tabs pick it up on their next page load.
          </p>
        </.settings_group>

        <.settings_group title="Mail">
          <.setting_field name="smtp_host" label="SMTP host" value={@settings[:smtp_host]} />
          <.setting_field name="smtp_port" label="SMTP port" value={@settings[:smtp_port]} />
          <.setting_field
            name="smtp_username"
            label="SMTP username"
            value={@settings[:smtp_username]}
          />
          <.secret_setting_field
            name="smtp_password"
            label="SMTP password"
            value={@settings[:smtp_password]}
          />
          <.setting_field name="mail_from" label="Mail from address" value={@settings[:mail_from]} />
          <p class="pt-1 font-mono text-[11px] text-muted-foreground">
            Applies to the next email sent — nothing to restart. Clear the host to fall back to
            the in-memory mailbox at /console/mailbox.
          </p>
        </.settings_group>

        <.settings_group title="Management API">
          <.secret_setting_field
            name="api_token"
            label="Bearer token"
            value={@settings[:api_token]}
          />
          <p class="pt-1 font-mono text-[11px] text-muted-foreground">
            Unset or empty disables the management API. Applies immediately.
          </p>
        </.settings_group>

        <.settings_group title="Analytics">
          <.setting_field
            name="analytics_src"
            label="Script URL"
            value={@settings[:analytics_src]}
          />
          <.setting_field
            name="analytics_domain"
            label="Domain"
            value={@settings[:analytics_domain]}
          />
          <p class="pt-1 font-mono text-[11px] text-muted-foreground">
            Both fields are required for the snippet to appear. Plausible-compatible.
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

  # ── section: backup ───────────────────────────────────────────
  attr :uploads, :map, required: true
  attr :trigger_export, :boolean, required: true
  attr :import_preview, :any, default: nil
  attr :import_error, :any, default: nil
  attr :has_ciphertext, :boolean, required: true

  defp backup_view(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-4">
      <.settings_group title="Export">
        <p class="text-sm text-muted-foreground">
          Downloads settings, apps, providers and webhooks, sealed with the password below. The
          file contains SMTP credentials, the management API token, webhook signing secrets and
          upstream provider client secrets — everything needed to impersonate this instance's
          integrations. Treat it, and the password, accordingly.
        </p>
        <.form
          for={%{}}
          action={~p"/console/backup/export"}
          method="post"
          id="export-form"
          phx-submit="prepare_export"
          phx-trigger-action={@trigger_export}
          class="space-y-3"
        >
          <div class="flex items-end gap-2 [&_>div]:mb-0">
            <div class="flex-1">
              <.input
                type="password"
                name="password"
                label={"Password (#{Vault.min_password_length()}+ characters)"}
                value=""
                autocomplete="new-password"
                minlength={Vault.min_password_length()}
                required
              />
            </div>
          </div>
          <div class="flex items-end gap-2 [&_>div]:mb-0">
            <div class="flex-1">
              <.input
                type="password"
                name="password_confirmation"
                label="Confirm password"
                value=""
                autocomplete="new-password"
                minlength={Vault.min_password_length()}
                required
              />
            </div>
            <.button type="submit">Export bundle</.button>
          </div>
          <p class="font-mono text-[11px] text-muted-foreground">
            Used exactly twice — now, and on the day you need to restore this. There is no reset:
            get it wrong here and the file is unrecoverable.
          </p>
        </.form>
      </.settings_group>

      <.settings_group title="Import">
        <p class="text-sm text-muted-foreground">
          Upserts by natural key and never deletes — an instance that has diverged keeps whatever
          the bundle doesn't mention. Review the counts below before applying.
        </p>

        <form
          id="import-form"
          phx-submit="preview_import"
          phx-change="validate_import"
          class="space-y-3"
        >
          <.live_file_input upload={@uploads.bundle} class="text-sm" />
          <div :for={entry <- @uploads.bundle.entries} class="flex items-center gap-2 text-xs">
            <span class="font-mono text-muted-foreground">
              {entry.client_name} ({entry.progress}%)
            </span>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="text-signal-down hover:underline"
            >
              remove
            </button>
          </div>
          <div :if={@has_ciphertext} class="flex items-center gap-2">
            <p class="font-mono text-[11px] text-signal-ok">
              File loaded — enter the password and decrypt.
            </p>
            <button
              type="button"
              phx-click="cancel_import"
              class="font-mono text-[11px] text-muted-foreground hover:underline"
            >
              remove
            </button>
          </div>

          <.input
            type="password"
            name="password"
            label="Password"
            value=""
            autocomplete="off"
            required
          />

          <.button type="submit" variant="outline">Decrypt &amp; preview</.button>
        </form>

        <p :if={@import_error} class="font-mono text-[11px] text-signal-down">
          Could not read this bundle: {import_error_copy(@import_error)}.
        </p>

        <div :if={@import_preview} class="space-y-4 rounded-md border border-border bg-muted/30 p-3">
          <div class="text-xs font-medium">This bundle will change:</div>

          <div
            :if={@import_preview.privileged?}
            class="flex items-start gap-2 rounded-md border border-signal-down/40 bg-signal-down/10 px-3 py-2 text-xs text-signal-down"
          >
            <span class="lucide-triangle-alert size-4 shrink-0 block" />
            <span>
              This bundle changes privileged instance configuration — credentials, distribution
              access, mail routing, or a first-party app or enabled identity provider. Review every
              highlighted line below before applying.
            </span>
          </div>

          <div
            :if={@import_preview.ignored_settings != []}
            class="rounded-md border border-signal-warn/40 bg-signal-warn/10 px-3 py-2 text-xs"
          >
            Ignored — instance identity, never carried by a bundle:
            <span class="font-mono">{Enum.join(@import_preview.ignored_settings, ", ")}</span>
          </div>

          <div :if={@import_preview.settings != []} class="space-y-1">
            <div class="font-mono text-[11px] uppercase tracking-wide text-muted-foreground">
              Settings
            </div>
            <dl class="space-y-1 text-xs">
              <div
                :for={s <- @import_preview.settings}
                class={[
                  "flex justify-between gap-4 border-b border-border/60 pb-1 last:border-0",
                  privileged_row?(s.privileged?, s.status != :unchanged) &&
                    "font-medium text-signal-down"
                ]}
              >
                <dt class="font-mono">{s.key}</dt>
                <dd class="font-mono text-right break-all">{setting_change_text(s)}</dd>
              </div>
            </dl>
          </div>

          <div :if={@import_preview.apps != []} class="space-y-1">
            <div class="font-mono text-[11px] uppercase tracking-wide text-muted-foreground">
              Apps
            </div>
            <dl class="space-y-1 text-xs">
              <div
                :for={a <- @import_preview.apps}
                class={[
                  "flex justify-between gap-4 border-b border-border/60 pb-1 last:border-0",
                  privileged_row?(a.privileged?, a.action != :unchanged) &&
                    "font-medium text-signal-down"
                ]}
              >
                <dt class="font-mono">
                  {a.slug} <span class="text-muted-foreground">({action_label(a.action)})</span>
                  <span :if={a.first_party} class="text-signal-down">1st-party</span>
                </dt>
                <dd class="font-mono text-right break-all">{a.callback_url}</dd>
              </div>
            </dl>
          </div>

          <div :if={@import_preview.identity_providers != []} class="space-y-1">
            <div class="font-mono text-[11px] uppercase tracking-wide text-muted-foreground">
              Identity providers
            </div>
            <dl class="space-y-1 text-xs">
              <div
                :for={p <- @import_preview.identity_providers}
                class={[
                  "space-y-0.5 border-b border-border/60 pb-1 last:border-0",
                  privileged_row?(p.privileged?, p.action != :unchanged) &&
                    "font-medium text-signal-down"
                ]}
              >
                <div class="flex justify-between gap-4">
                  <dt class="font-mono">
                    {p.slug} <span class="text-muted-foreground">({action_label(p.action)})</span>
                    <span :if={p.enabled} class="text-signal-down">enabled</span>
                  </dt>
                </div>
                <dd class="font-mono break-all text-muted-foreground">
                  authorize: {p.authorize_url} · token: {p.token_url} · userinfo: {p.userinfo_url}
                </dd>
              </div>
            </dl>
          </div>

          <div :if={@import_preview.webhook_endpoints != []} class="space-y-1">
            <div class="font-mono text-[11px] uppercase tracking-wide text-muted-foreground">
              Webhook endpoints
            </div>
            <dl class="space-y-1 text-xs">
              <div
                :for={e <- @import_preview.webhook_endpoints}
                class="flex justify-between gap-4 border-b border-border/60 pb-1 last:border-0"
              >
                <dt class="font-mono text-muted-foreground">({action_label(e.action)})</dt>
                <dd class="font-mono text-right break-all">{e.url}</dd>
              </div>
            </dl>
          </div>

          <div class="flex justify-end gap-2">
            <.button type="button" variant="outline" phx-click="cancel_import">Cancel</.button>
            <.button
              type="button"
              phx-click="apply_import"
              data-confirm="Apply this bundle? Matching settings, apps, providers and webhooks are overwritten; nothing is deleted."
            >
              Apply import
            </.button>
          </div>
        </div>
      </.settings_group>
    </div>
    """
  end

  defp import_error_copy(:wrong_password), do: "wrong password"
  defp import_error_copy(:malformed), do: "not a bundle"
  defp import_error_copy(:unsupported_version), do: "exported by a newer version of You"

  defp privileged_row?(privileged?, changed?), do: privileged? and changed?

  defp action_label(:create), do: "create"
  defp action_label(:update), do: "update"
  defp action_label(:unchanged), do: "unchanged"

  defp setting_change_text(%{secret?: true, status: status}), do: status_label(status)

  defp setting_change_text(%{status: :unchanged, new: new}),
    do: "unchanged (#{display_value(new)})"

  defp setting_change_text(%{old: old, new: new}),
    do: "#{display_value(old)} → #{display_value(new)}"

  defp status_label(:unchanged), do: "unchanged"
  defp status_label(:set), do: "set"
  defp status_label(:cleared), do: "cleared"
  defp status_label(:changed), do: "changed"

  defp display_value(nil), do: "(empty)"
  defp display_value(""), do: "(empty)"
  defp display_value(value), do: to_string(value)

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
