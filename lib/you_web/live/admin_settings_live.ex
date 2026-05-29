defmodule YouWeb.AdminSettingsLive do
  use YouWeb, :live_view

  alias You.Settings

  @defaults %{
    session_expiry_hours: 24,
    jwt_expiry_hours: 1,
    code_expiry_minutes: 5,
    magic_link_expiry_minutes: 15
  }

  @impl true
  def mount(_params, _session, socket) do
    settings = load_settings()

    {:ok,
     socket
     |> assign(:settings, settings)
     |> assign(:saved, false)}
  end

  @impl true
  def handle_event("save", params, socket) do
    settings = socket.assigns.settings

    settings =
      Enum.map(settings, fn {key, _current_value} ->
        key_str = Atom.to_string(key)

        case Integer.parse(params[key_str] || "") do
          {value, ""} when value >= 0 ->
            Settings.set(key, value)
            {key, value}

          _ ->
            {key, settings[key]}
        end
      end)
      |> Map.new()

    {:noreply, assign(socket, settings: settings, saved: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1 class="text-xl font-bold mb-4">Settings</h1>

    <div :if={@saved} class="alert alert-success mb-4">
      Settings saved.
    </div>

    <form phx-submit="save" class="space-y-4 max-w-md">
      <div :for={{key, value} <- @settings} class="fieldset">
        <label class="label">
          <span class="label-text"><%= key |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize() %></span>
        </label>
        <input
          type="number"
          min="0"
          name={Atom.to_string(key)}
          value={value}
          class="input input-bordered w-full"
        />
      </div>

      <button type="submit" class="btn btn-primary">
        Save Settings
      </button>
    </form>
    """
  end

  defp load_settings do
    @defaults
    |> Enum.map(fn {key, _default} ->
      {key, Settings.get(key)}
    end)
    |> Map.new()
  end
end
