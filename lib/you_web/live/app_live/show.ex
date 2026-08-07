defmodule YouWeb.AppLive.Show do
  @moduledoc """
  Per-app console page at `/console/apps/:slug`.

  Splits what used to be a single edit dialog into tabs: identity and URLs,
  login branding, the app's `allowed_roles`, who holds them, and the client
  credentials. The active tab is a path segment
  (`/console/apps/:slug/:tab`), so a tab is linkable.
  """
  use YouWeb, :live_view

  import YouWeb.Components.ConsoleChrome

  alias You.{Admin, Roles}
  alias YouWeb.RequestURL

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
       preview_theme: "light",
       providers: You.IdentityProviders.list_enabled_providers(),
       member_filter: ""
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
    |> Admin.update_app(
      Map.take(params, ["name", "callback_url", "launch_url", "hostname_label", "first_party"])
    )
    |> reload(socket, "App updated.")
  end

  def handle_event("update_custom_claims", %{"custom_claims" => json}, socket) do
    case decode_claims(json) do
      {:ok, claims} ->
        socket.assigns.app
        |> Admin.update_app(%{"custom_claims" => claims})
        |> reload(socket, "Custom claims updated.")

      :error ->
        {:noreply, put_flash(socket, :error, "That is not valid JSON.")}
    end
  end

  def handle_event("update_lifetimes", params, socket) do
    attrs =
      params
      |> Map.take(["jwt_expiry_hours", "code_expiry_minutes"])
      |> Map.new(fn {key, value} -> {key, blank_to_nil(value)} end)

    socket.assigns.app
    |> Admin.update_app(attrs)
    |> reload(socket, "Token lifetimes updated.")
  end

  # ── login branding ────────────────────────────────────────────
  def handle_event("preview_branding", params, socket) do
    {:noreply,
     assign(socket,
       draft: %{
         logo_url: safe_logo_url(params["logo_url"]),
         brand_color: safe_brand_color(params["brand_color"]),
         accent_color: safe_brand_color(params["accent_color"]),
         brand_color_dark: safe_brand_color(params["brand_color_dark"]),
         accent_color_dark: safe_brand_color(params["accent_color_dark"]),
         headline: safe_copy(params["headline"]),
         subtitle: safe_copy(params["subtitle"])
       }
     )}
  end

  def handle_event("update_branding", params, socket) do
    socket.assigns.app
    |> Admin.update_app(
      Map.take(params, [
        "accent_color",
        "accent_color_dark",
        "brand_color",
        "brand_color_dark",
        "headline",
        "logo_url",
        "subtitle"
      ])
    )
    |> reload(socket, "Branding updated.")
  end

  def handle_event("toggle_preview_theme", _params, socket) do
    theme = if socket.assigns.preview_theme == "dark", do: "light", else: "dark"
    {:noreply, assign(socket, preview_theme: theme)}
  end

  # ── consent screen ────────────────────────────────────────────
  def handle_event("update_consent_urls", params, socket) do
    socket.assigns.app
    |> Admin.update_app(Map.take(params, ["tos_url", "privacy_url", "email_from_name"]))
    |> reload(socket, "Consent screen updated.")
  end

  def handle_event("update_theme_mode", %{"theme_mode" => mode}, socket) do
    socket.assigns.app
    |> Admin.update_app(%{"theme_mode" => mode})
    |> reload(socket, "Theme updated.")
  end

  def handle_event("update_providers", params, socket) do
    ticked = for {slug, "true"} <- Map.get(params, "providers", %{}), do: slug
    all = Enum.map(socket.assigns.providers, & &1.slug)
    checked = Enum.filter(all, &(&1 in ticked))

    # Explicit, same as sign-in methods: nil is a chosen state, not one
    # inferred from having every box ticked.
    providers = if params["follow_instance"] == "true", do: nil, else: checked

    socket.assigns.app
    |> Admin.update_app(%{"enabled_providers" => providers})
    |> reload(socket, "Identity providers updated.")
  end

  def handle_event("update_methods", params, socket) do
    ticked = for {method, "true"} <- Map.get(params, "methods", %{}), do: method

    # Params arrive as a map, so the comprehension's order is arbitrary. Filter
    # the canonical list instead, to store a stable order.
    checked = Enum.filter(You.Admin.App.auth_methods(), &(&1 in ticked))

    # nil means "follow the instance". That is now an explicit choice on the
    # form rather than something inferred from having ticked every box, so
    # unticking and reticking a method no longer silently changes the meaning
    # of the record.
    methods = if params["follow_instance"] == "true", do: nil, else: checked

    socket.assigns.app
    |> Admin.update_app(%{"enabled_methods" => methods})
    |> reload(socket, "Sign-in methods updated.")
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

  def handle_event("stage_default_role", %{"value" => role}, socket) do
    {:noreply, assign(socket, pending_default_role: role)}
  end

  def handle_event("set_default_role", %{"default_role" => role}, socket) do
    socket.assigns.app
    |> Admin.set_default_role(role)
    |> reload(socket, "Default role updated.")
  end

  # ── members ───────────────────────────────────────────────────
  def handle_event("set_member_role", %{"user_id" => user_id} = params, socket) do
    app = socket.assigns.app

    with {:ok, id} <- safe_parse_id(user_id),
         %{} = user <- Admin.get_user!(id) do
      role = params["value"] || params["role"]

      case Roles.set_role(app, user, role) do
        {:ok, _} ->
          {:noreply, assign_app(socket, app)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Role is not allowed for this app.")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Invalid user.")}
    end
  end

  def handle_event("invite_member", %{"email" => email} = params, socket) do
    app = socket.assigns.app

    attrs = %{
      email: email,
      app_id: app.id,
      role: params["role"] || params["value"] || app.default_role || "user",
      invited_by_id: socket.assigns.current_scope.user.id
    }

    invite_url_fun = &RequestURL.url(socket, ~p"/invitations/#{&1}")

    case You.Invitations.invite(attrs, invite_url_fun) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> assign_app(app)
         |> put_flash(:info, "Invitation sent to #{invitation.email}.")}

      {:error, :invalid_role} ->
        {:noreply, put_flash(socket, :error, "Role is not allowed for this app.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, "Could not invite: #{error_summary(changeset)}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not send that invitation.")}
    end
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    with {:ok, invitation_id} <- safe_parse_id(id) do
      You.Invitations.revoke(invitation_id)
    end

    {:noreply,
     socket |> assign_app(socket.assigns.app) |> put_flash(:info, "Invitation withdrawn.")}
  end

  def handle_event("filter_members", %{"query" => query}, socket) do
    {:noreply, assign(socket, member_filter: query)}
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
        accent_color: app.accent_color,
        brand_color_dark: app.brand_color_dark,
        accent_color_dark: app.accent_color_dark,
        headline: app.headline,
        subtitle: app.subtitle
      },
      members: Roles.list_for_app(app),
      invitations: Enum.filter(You.Invitations.list_pending(), &(&1.app_id == app.id)),
      role_counts: Roles.count_by_role(app),
      pending_default_role: app.default_role || "user"
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

  # Filtering is presentation only: a hidden row stays selected, so a bulk
  # action after searching does not silently drop rows the admin had ticked.
  defp filter_members(members, ""), do: members

  defp filter_members(members, query) do
    needle = String.downcase(query)

    Enum.filter(members, fn {user, _} -> String.contains?(String.downcase(user.email), needle) end)
  end

  # Parses a user id that arrives over the socket from a <.select> hook's params.
  # The client can push any payload, so reject non-integer values rather than
  # raising Ecto.Query.CastError in Repo.get!.
  defp safe_parse_id(id) when is_integer(id), do: {:ok, id}

  defp safe_parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp safe_parse_id(_), do: :error

  defp theme_mode_label("system"), do: "Follow the visitor's preference"
  defp theme_mode_label("light"), do: "Always light"
  defp theme_mode_label("dark"), do: "Always dark"

  defp enabled_providers(app, all),
    do: You.Admin.App.resolved_providers(app, Enum.map(all, & &1.slug))

  defp enabled_methods(app),
    do: You.Admin.App.resolved_methods(app, You.Admin.App.auth_methods())

  defp method_label("magic_link"), do: "Magic link"
  defp method_label(method), do: method |> String.capitalize()

  # ── render ────────────────────────────────────────────────────
  @impl true
  def render(assigns) do
    ~H"""
    <.console_shell nav={@nav} active={app_nav_id()} title="Apps" node_name={@node_name}>
      <div class="space-y-5">
        <div>
          <.link
            navigate={~p"/console/apps"}
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
            <.login_tab
              app={@app}
              draft={@draft}
              preview_theme={@preview_theme}
              providers={@providers}
            />
          <% "roles" -> %>
            <.roles_tab
              app={@app}
              roles={allowed_roles(@app)}
              counts={@role_counts}
              default_role={@app.default_role || "user"}
              pending_default_role={@pending_default_role}
            />
          <% "members" -> %>
            <.members_tab
              app={@app}
              members={filter_members(@members, @member_filter)}
              filter={@member_filter}
              roles={allowed_roles(@app)}
              selected={@selected}
              invitations={@invitations}
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
          type="text"
          name="hostname_label"
          label="Hostname label (optional)"
          value={@app.hostname_label}
          placeholder={@app.slug}
        />
        <p :if={hostname_preview(@app)} class="text-xs text-muted-foreground">
          Serves this app's login pages at <span class="font-mono">{hostname_preview(@app)}</span>.
        </p>
        <p :if={!hostname_preview(@app)} class="text-xs text-muted-foreground">
          Blank keeps this app on the canonical host, exactly as today. Does not change the
          client_id — see Credentials.
        </p>
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

    <.panel
      title="Token lifetimes"
      description="How long this app's credentials stay valid. Leave blank to follow the instance settings."
    >
      <form id="app-lifetimes-form" phx-submit="update_lifetimes" class="max-w-xl space-y-4">
        <.input
          type="number"
          name="jwt_expiry_hours"
          label="JWT expiry (hours)"
          min="1"
          max={You.Admin.App.max_jwt_expiry_hours()}
          placeholder={"instance default: #{You.Settings.get(:jwt_expiry_hours)}"}
          value={@app.jwt_expiry_hours}
        />
        <.input
          type="number"
          name="code_expiry_minutes"
          label="Auth code expiry (minutes)"
          min="1"
          max={You.Admin.App.max_code_expiry_minutes()}
          placeholder={"instance default: #{You.Settings.get(:code_expiry_minutes)}"}
          value={@app.code_expiry_minutes}
        />
        <p class="text-xs text-muted-foreground">
          A session on You itself is one cookie across every app, so its expiry stays an
          instance setting.
        </p>
        <div class="flex justify-end">
          <.button type="submit">Save</.button>
        </div>
      </form>
    </.panel>

    <.panel
      title="Custom claims"
      description="Static values merged into every JWT issued for this app, so it can read them from the token instead of fetching them."
    >
      <form id="app-claims-form" phx-submit="update_custom_claims" class="max-w-xl space-y-4">
        <.input
          type="textarea"
          name="custom_claims"
          label="Claims (JSON object)"
          rows="6"
          value={claims_json(@app)}
          placeholder={~s({"tenant_id": "acme", "plan": "pro"})}
        />
        <p class="text-xs text-muted-foreground">
          Values may be strings, numbers, booleans, or lists of those. Claims You issues — {Enum.join(
            You.Admin.App.reserved_claims(),
            ", "
          )} — cannot be set here.
          At most {You.Admin.App.max_custom_claims_bytes()} bytes: a JWT travels in a header.
        </p>
        <div class="flex justify-end">
          <.button type="submit">Save</.button>
        </div>
      </form>
    </.panel>
    """
  end

  defp claims_json(%{custom_claims: claims}) when is_map(claims) and map_size(claims) > 0,
    do: Jason.encode!(claims, pretty: true)

  defp claims_json(_app), do: ""

  # nil when the app has no label, or when the feature/template that would
  # make the label resolve to anything isn't fully configured — a label
  # sitting on the row unused is not "serving this app" yet.
  defp hostname_preview(%{hostname_label: label}) when is_binary(label) do
    if You.Hosting.enabled?(), do: You.Hosting.render_hostname(label)
  end

  defp hostname_preview(_app), do: nil

  # An empty box means "no extra claims", stored as an empty object rather
  # than left as whatever the app had before.
  defp decode_claims(json) do
    case String.trim(json || "") do
      "" -> {:ok, %{}}
      trimmed -> decode_claims_json(trimmed)
    end
  end

  defp decode_claims_json(json) do
    case Jason.decode(json) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _ -> :error
    end
  end

  # An empty field means "follow the instance", which on the column is NULL —
  # not the zero an empty string would otherwise try to cast to.
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  attr :app, :map, required: true
  attr :draft, :map, required: true
  attr :preview_theme, :string, required: true
  attr :providers, :list, required: true

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
            <.color_input
              id="app-brand-color"
              name="brand_color"
              label="Brand color (optional)"
              value={@draft.brand_color}
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
            <.color_input
              id="app-accent-color"
              name="accent_color"
              label="Accent color (optional)"
              value={@draft.accent_color}
            />
            <.color_input
              id="app-brand-color-dark"
              name="brand_color_dark"
              label="Brand color — dark mode (optional)"
              value={@draft.brand_color_dark}
            />
            <.color_input
              id="app-accent-color-dark"
              name="accent_color_dark"
              label="Accent color — dark mode (optional)"
              value={@draft.accent_color_dark}
            />
            <div class="flex justify-end">
              <.button type="submit">Save</.button>
            </div>
          </form>
        </.panel>

        <.panel
          title="Theme"
          description="Which themes this app's login page offers. Forcing one overrides the visitor's own preference."
        >
          <form id="app-theme-form" phx-submit="update_theme_mode" class="space-y-3">
            <.input
              type="select"
              name="theme_mode"
              label="Theme"
              value={@app.theme_mode || "system"}
              options={Enum.map(You.Admin.App.theme_modes(), &{theme_mode_label(&1), &1})}
            />
            <div class="flex justify-end">
              <.button type="submit">Save</.button>
            </div>
          </form>
        </.panel>

        <.panel
          title="Identity providers"
          description="Which upstream providers this app offers. Enforced server-side, not only hidden here."
        >
          <form id="app-providers-form" phx-submit="update_providers" class="space-y-3">
            <p :if={@providers == []} class="text-xs text-muted-foreground">
              No providers configured yet. Add one under Providers in the console.
            </p>
            <.input
              :for={provider <- @providers}
              type="checkbox"
              name={"providers[#{provider.slug}]"}
              label={provider.display_name || provider.slug}
              value="true"
              checked={provider.slug in enabled_providers(@app, @providers)}
            />
            <label :if={@providers != []} class="flex items-start gap-3 border-t border-border pt-3">
              <input type="hidden" name="follow_instance" value="false" />
              <input
                type="checkbox"
                name="follow_instance"
                value="true"
                checked={not You.Admin.App.restricts_providers?(@app)}
                class="mt-0.5 size-4 rounded border-border"
              />
              <span>
                <span class="block text-sm">Offer every provider this instance enables</span>
                <span class="block text-xs text-muted-foreground">
                  Follows You rather than pinning a list. Untick to restrict to the boxes above.
                </span>
              </span>
            </label>
            <div :if={@providers != []} class="flex justify-end">
              <.button type="submit">Save</.button>
            </div>
          </form>
        </.panel>

        <.panel
          title="Sign-in methods"
          description="Which methods this app's users may use. Disabling one hides its control and rejects it server-side."
        >
          <form id="app-methods-form" phx-submit="update_methods" class="space-y-3">
            <.input
              :for={method <- You.Admin.App.auth_methods()}
              type="checkbox"
              name={"methods[#{method}]"}
              label={method_label(method)}
              value="true"
              checked={method in enabled_methods(@app)}
            />
            <label class="flex items-start gap-3 border-t border-border pt-3">
              <input type="hidden" name="follow_instance" value="false" />
              <input
                type="checkbox"
                name="follow_instance"
                value="true"
                checked={not You.Admin.App.restricts_methods?(@app)}
                class="mt-0.5 size-4 rounded border-border"
              />
              <span>
                <span class="block text-sm">Offer everything this instance supports</span>
                <span class="block text-xs text-muted-foreground">
                  Follows You rather than pinning a list, so a method added later reaches this app.
                  Untick to restrict to the boxes above.
                </span>
              </span>
            </label>
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
            <.input
              type="text"
              name="email_from_name"
              label="Email sender name (optional)"
              value={@app.email_from_name}
              placeholder="You"
            />
            <div class="flex justify-end">
              <.button type="submit">Save</.button>
            </div>
          </form>
        </.panel>
      </div>

      <.panel title="Preview" description="The login page, with unsaved values applied.">
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
            brand_color_dark={presence(@draft.brand_color_dark)}
            accent_color={presence(@draft.accent_color)}
            accent_color_dark={presence(@draft.accent_color_dark)}
            headline={presence(@draft.headline)}
            subtitle={presence(@draft.subtitle)}
          />

          <div class="mx-auto mt-6 max-w-xs space-y-3 text-left">
            <div>
              <label class="mb-1 block text-xs font-medium text-muted-foreground">Email</label>
              <div class="h-9 rounded-md border border-input bg-background px-3 text-sm leading-9 text-muted-foreground/60">
                you@example.com
              </div>
            </div>
            <div>
              <label class="mb-1 block text-xs font-medium text-muted-foreground">Password</label>
              <div class="h-9 rounded-md border border-input bg-background px-3 text-sm leading-9 text-muted-foreground/60">
                ••••••••••
              </div>
            </div>
            <div
              class="grid h-9 place-items-center rounded-md text-sm font-medium"
              style={preview_button_style(@draft, @preview_theme)}
            >
              Sign in
            </div>
            <p class="text-center text-xs text-muted-foreground">
              {preview_methods_label(@app)}
            </p>
          </div>
        </div>
        <p class="mt-3 text-xs text-muted-foreground">
          <.link
            href={~p"/users/log-in?#{[app: @app.slug]}"}
            target="_blank"
            class="underline underline-offset-2 hover:text-foreground"
          >
            Open the real login page
          </.link>
          — saved values only, no callback URL needed.
        </p>
      </.panel>
    </div>
    """
  end

  # A blank form field means "no value", but `""` would render as a logo with an
  # empty src and an empty style attribute.
  defp presence(""), do: nil
  defp presence(value), do: value

  defp preview_button_style(draft, theme) do
    color =
      if theme == "dark",
        do: presence(draft.brand_color_dark) || presence(draft.brand_color),
        else: presence(draft.brand_color)

    case safe_brand_color(color) do
      nil -> "background-color: var(--color-primary); color: var(--color-primary-foreground)"
      hex -> "background-color: #{hex}; color: #{You.Admin.App.contrast_on(hex)}"
    end
  end

  defp preview_methods_label(app) do
    case YouWeb.AuthMethods.previewed_methods(app) -- ["password"] do
      [] -> "Password sign-in only"
      others -> "Also: " <> Enum.map_join(others, ", ", &String.replace(&1, "_", " "))
    end
  end

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
  attr :pending_default_role, :string, required: true

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

        <form id="app-add-role-form" phx-submit="add_role" class="flex items-end gap-2 [&_>div]:mb-0">
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
          <%!-- The select sits outside the form on purpose. A click inside a
                data-confirm form raises the prompt before the dropdown even
                opens, so picking a value would ask "are you sure" about a
                change not yet made. Choosing stages the value; only Save
                confirms. --%>
          <div class="flex items-center gap-2">
            <.select
              id="app-default-role"
              value={@pending_default_role}
              options={Enum.map(@roles, &%{value: &1, label: &1})}
              on_change="stage_default_role"
            />
            <form
              id="app-default-role-form"
              phx-submit="set_default_role"
              data-confirm="Change the default role? Every user without an explicit assignment gets the new role in their next token."
            >
              <input type="hidden" name="default_role" value={@pending_default_role} />
              <.button
                type="submit"
                size="sm"
                variant="outline"
                disabled={@pending_default_role == @default_role}
              >
                Set default
              </.button>
            </form>
          </div>
        </div>
      </div>
    </.panel>
    """
  end

  attr :app, :map, required: true
  attr :members, :list, required: true
  attr :roles, :list, required: true
  attr :selected, :any, required: true
  attr :filter, :string, required: true
  attr :invitations, :list, required: true

  defp members_tab(assigns) do
    ~H"""
    <div class="space-y-3">
      <%!-- Registration and a SCIM push from an upstream directory are the only
            other ways in, and neither lets an operator onboard one named
            person. --%>
      <div class="rounded-md border border-border bg-muted/20 px-3 py-3">
        <form
          id="invite-member-form"
          phx-submit="invite_member"
          class="flex flex-wrap items-end gap-2 [&_>div]:mb-0"
        >
          <div class="min-w-56 flex-1">
            <.input type="email" name="email" value="" label="Invite by email" required />
          </div>
          <.select
            id="invite-role"
            name="role"
            value="user"
            options={Enum.map(@roles, &%{value: &1, label: &1})}
          />
          <.button type="submit">Send invitation</.button>
        </form>

        <ul :if={@invitations != []} class="mt-3 space-y-1 border-t border-border pt-3">
          <li
            :for={invitation <- @invitations}
            class="flex items-center justify-between gap-3 text-xs"
          >
            <span class="font-mono text-muted-foreground">
              {invitation.email} · {invitation.role || "user"} · invited {Calendar.strftime(
                invitation.inserted_at,
                "%Y-%m-%d"
              )}
            </span>
            <button
              type="button"
              phx-click="revoke_invitation"
              phx-value-id={invitation.id}
              data-confirm={"Withdraw the invitation to #{invitation.email}?"}
              class="text-muted-foreground hover:text-destructive"
            >
              Withdraw
            </button>
          </li>
        </ul>
      </div>

      <form phx-change="filter_members" class="flex items-center gap-2 [&_>div]:mb-0">
        <div class="flex-1">
          <.input
            type="text"
            name="query"
            value={@filter}
            placeholder="Search members by email"
            phx-debounce="200"
          />
        </div>
        <span class="shrink-0 font-mono text-xs text-muted-foreground">
          {length(@members)} shown
        </span>
      </form>

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
