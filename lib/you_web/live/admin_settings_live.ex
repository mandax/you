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
    %{key: :erlang_cookie, type: :password, label: "Erlang cookie"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, fields: @fields, settings: Settings.all(), saved: false)}
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

    {:noreply, assign(socket, settings: Settings.all(), saved: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab="settings">
      <:side_panel>
        <div class="text-[11px] font-medium text-base-content/40 uppercase tracking-widest">
          Settings
        </div>
        <a
          href="#general"
          class="text-sm text-base-content/60 hover:text-base-content transition-colors"
        >
          Session
        </a>
        <a
          href="#tokens"
          class="text-sm text-base-content/60 hover:text-base-content transition-colors"
        >
          Tokens &amp; Expiry
        </a>
        <a
          href="#erlang"
          class="text-sm text-base-content/60 hover:text-base-content transition-colors"
        >
          Erlang Distribution
        </a>
      </:side_panel>

      <div class="space-y-10">
        <div
          :if={@saved}
          class="rounded-lg border border-success/30 bg-success/5 p-4 text-sm text-success-content flex items-center gap-2"
        >
          <.icon name="check-circle" class="size-4 shrink-0 text-success" /> Settings saved.
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

          <div class="border-t border-base-300" />

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
            <p class="text-xs text-base-content/40 mt-3 leading-relaxed">
              The erlang cookie from settings is applied at boot and when saved in this form.
              It overrides the RELEASE_COOKIE env var. Changing the cookie breaks existing Erlang connections.
            </p>
          </section>

          <button type="submit" class="btn btn-primary">
            Save Settings
          </button>
        </form>
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
