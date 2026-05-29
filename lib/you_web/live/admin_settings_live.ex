defmodule YouWeb.AdminSettingsLive do
  use YouWeb, :live_view

  alias You.Settings

  @fields [
    %{key: :session_expiry_hours, type: :number, label: "Session expiry (hours)"},
    %{key: :jwt_expiry_hours, type: :number, label: "JWT expiry (hours)"},
    %{key: :code_expiry_minutes, type: :number, label: "Auth code expiry (minutes)"},
    %{key: :magic_link_expiry_minutes, type: :number, label: "Magic link expiry (minutes)"},
    %{key: :erlang_node_name, type: :text, label: "Erlang node name"},
    %{key: :epmd_port, type: :number, label: "EPMD port"}
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

      if is_binary(raw) and raw != "" do
        parsed = parse_value(raw)
        Settings.set(key, parsed)
      end
    end)

    {:noreply, assign(socket, settings: Settings.all(), saved: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="text-xl font-bold mb-4">Settings</h1>

    <div :if={@saved} class="alert alert-success mb-4">
      Settings saved.
    </div>

    <form phx-submit="save" class="space-y-4 max-w-md">
      <div :for={field <- @fields} class="fieldset">
        <label class="label">
          <span class="label-text"><%= field.label %></span>
        </label>
        <input
          type={if field.type == :number, do: "number", else: "text"}
          min={if field.type == :number, do: "0"}
          name={Atom.to_string(field.key)}
          value={@settings[field.key]}
          class="input input-bordered w-full"
        />
      </div>

      <button type="submit" class="btn btn-primary">
        Save Settings
      </button>
    </form>

    <div class="mt-8 text-sm text-base-content/60 space-y-1">
      <p class="font-semibold">Erlang distribution notes:</p>
      <p>
        The <code>erlang_node_name</code> and cookie must also be set via
        <code>RELEASE_NODE</code> and <code>RELEASE_COOKIE</code> environment
        variables when starting the container — database settings alone don't
        configure the Erlang VM's distribution layer.
      </p>
    </div>
    """
  end

  defp parse_value(raw) do
    cond do
      raw =~ ~r/^\d+$/ -> String.to_integer(raw)
      true -> raw
    end
  end
end
