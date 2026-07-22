defmodule YouWeb.AdminSettingsLive do
  use YouWeb, :live_view

  alias You.Settings

  @fields [
    %{key: :session_expiry_hours, type: :number, label: "Session expiry (hours)"},
    %{key: :jwt_expiry_hours, type: :number, label: "JWT expiry (hours)"},
    %{key: :code_expiry_minutes, type: :number, label: "Auth code expiry (minutes)"},
    %{key: :magic_link_expiry_minutes, type: :number, label: "Magic link expiry (minutes)"},
    %{key: :erlang_node_name, type: :text, label: "Erlang node name"},
    %{key: :epmd_port, type: :number, label: "EPMD port"},
    %{key: :erlang_cookie, type: :password, label: "Erlang cookie"},
    %{key: :scim_bearer_token, type: :password, label: "SCIM bearer token"},
    %{key: :audit_webhook_url, type: :text, label: "Audit webhook URL"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    base = YouWeb.Endpoint.url()
    providers = Application.get_env(:you, :oidc_providers, %{}) |> Map.keys()

    {:ok,
     assign(socket,
       fields: @fields,
       settings: Settings.all(),
       saved: false,
       base_url: base,
       oidc_providers: providers
     )}
  end

  @impl true
  def handle_event("save", params, socket) do
    Enum.each(@fields, fn field ->
      key = field.key
      key_str = Atom.to_string(key)
      raw = params[key_str]

      if is_binary(raw) do
        parsed = parse_value(raw)
        Settings.set(key, parsed)
      end
    end)

    # Apply the cookie immediately if it was changed
    You.Accounts.CookieSync.apply_cookie()
    # Refresh the audit streamer's cached webhook URL from the new setting
    You.Audit.Streamer.reload()

    {:noreply, assign(socket, settings: Settings.all(), saved: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab="settings">
      <:side_panel>
        <div class="text-[11px] font-medium text-muted-foreground uppercase tracking-widest">
          Settings
        </div>
        <a
          href="#general"
          class="text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          Session
        </a>
        <a
          href="#tokens"
          class="text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          Tokens &amp; Expiry
        </a>
        <a
          href="#erlang"
          class="text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          Erlang Distribution
        </a>
        <a
          href="#provisioning"
          class="text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          Provisioning &amp; Audit
        </a>
        <a
          href="#oidc"
          class="text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          OIDC &amp; Federation
        </a>
      </:side_panel>

      <div class="space-y-10">
        <div
          :if={@saved}
          class="rounded-lg border border-signal-ok/30 bg-signal-ok/5 p-4 text-sm text-foreground flex items-center gap-2"
        >
          <.icon name="check-circle" class="size-4 shrink-0 text-signal-ok" /> Settings saved.
        </div>

        <form phx-submit="save" class="space-y-8 max-w-md">
          <section id="general">
            <h2 class="text-lg font-medium tracking-tight mb-6">Session &amp; Token Expiry</h2>
            <div class="space-y-4">
              <.input
                type="number"
                name="session_expiry_hours"
                label="Session expiry (hours)"
                value={@settings[:session_expiry_hours]}
              />
              <.input
                type="number"
                name="jwt_expiry_hours"
                label="JWT expiry (hours)"
                value={@settings[:jwt_expiry_hours]}
              />
              <.input
                type="number"
                name="code_expiry_minutes"
                label="Auth code expiry (minutes)"
                value={@settings[:code_expiry_minutes]}
              />
              <.input
                type="number"
                name="magic_link_expiry_minutes"
                label="Magic link expiry (minutes)"
                value={@settings[:magic_link_expiry_minutes]}
              />
            </div>
          </section>

          <div class="border-t border-border" />

          <section id="erlang">
            <h2 class="text-lg font-medium tracking-tight mb-6">Erlang Distribution</h2>
            <div class="space-y-4">
              <.input
                type="text"
                name="erlang_node_name"
                label="Erlang node name"
                value={@settings[:erlang_node_name]}
              />
              <.input
                type="number"
                name="epmd_port"
                label="EPMD port"
                value={@settings[:epmd_port]}
              />
              <.input
                type="password"
                name="erlang_cookie"
                label="Erlang cookie"
                value={@settings[:erlang_cookie]}
              />
            </div>
            <p class="text-xs text-muted-foreground mt-3 leading-relaxed">
              The erlang cookie from settings is applied at boot and when saved in this form.
              It overrides the RELEASE_COOKIE env var. Changing the cookie breaks existing Erlang connections.
            </p>
          </section>

          <div class="border-t border-border" />

          <section id="provisioning">
            <h2 class="text-lg font-medium tracking-tight mb-6">Provisioning &amp; Audit</h2>
            <div class="space-y-4">
              <.input
                type="password"
                name="scim_bearer_token"
                label="SCIM bearer token"
                value={@settings[:scim_bearer_token]}
              />
              <p class="text-xs text-muted-foreground -mt-2">
                Directory sync (Okta, Azure AD) authenticates to
                <code>{@base_url}/scim/v2</code>
                with this token. Blank disables SCIM.
              </p>
              <.input
                type="text"
                name="audit_webhook_url"
                label="Audit webhook URL"
                value={@settings[:audit_webhook_url]}
              />
              <p class="text-xs text-muted-foreground -mt-2">
                Security events are POSTed here as JSON. Blank disables streaming.
              </p>
            </div>
          </section>

          <.button type="submit">
            Save Settings
          </.button>
        </form>

        <div class="border-t border-border" />

        <section id="oidc" class="max-w-md space-y-4">
          <h2 class="text-lg font-medium tracking-tight">OIDC &amp; Federation</h2>
          <p class="text-sm text-muted-foreground">
            Standard OpenID Connect discovery endpoints for third-party consumers.
          </p>
          <.list>
            <:item title="Discovery">
              <code class="text-xs">{@base_url}/.well-known/openid-configuration</code>
            </:item>
            <:item title="JWKS">
              <code class="text-xs">{@base_url}/.well-known/jwks.json</code>
            </:item>
            <:item title="Token">
              <code class="text-xs">{@base_url}/oauth/token</code>
            </:item>
          </.list>
          <div>
            <h3 class="text-sm font-medium mb-2">Upstream identity providers</h3>
            <p :if={@oidc_providers == []} class="text-xs text-muted-foreground">
              None configured. Set <code>config :you, :oidc_providers</code>
              to enable “Sign in with …”.
            </p>
            <div :if={@oidc_providers != []} class="flex flex-wrap gap-2">
              <.badge :for={p <- @oidc_providers} variant="info">{p}</.badge>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp parse_value(raw) do
    cond do
      raw =~ ~r/^\d+$/ -> String.to_integer(raw)
      true -> raw
    end
  end
end
