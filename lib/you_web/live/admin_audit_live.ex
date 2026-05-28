defmodule YouWeb.AdminAuditLive do
  use YouWeb, :live_view

  alias You.Audit.Reader

  @impl true
  def mount(_params, _session, socket) do
    categories = Reader.categories()
    events = if categories != [], do: Reader.read(hd(categories)), else: []

    {:ok,
     socket
     |> assign(:categories, categories)
     |> assign(:selected_category, hd(categories) || "login")
     |> assign(:events, events)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    category = params["category"] || socket.assigns.selected_category
    events = Reader.read(category)
    {:noreply, assign(socket, selected_category: category, events: events)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <h1>Audit Log</h1>

    <div class="tabs tabs-box mb-4">
      <.link
        :for={cat <- @categories}
        patch={"/admin/audit?category=" <> cat}
        class={"tab " <> if cat == @selected_category, do: "tab-active", else: ""}
      >
        {cat}
      </.link>
    </div>

    <div class="overflow-x-auto">
      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Time</th>
            <th>Event</th>
            <th>Details</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @events}>
            <td class="text-sm">{event["ts"]}</td>
            <td>{event["event"]}</td>
            <td class="text-sm">{inspect(event)}</td>
          </tr>
        </tbody>
      </table>
    </div>

    <div :if={@events == []} class="text-center py-8 text-base-content/50">
      No audit events found.
    </div>
    """
  end
end
