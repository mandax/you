defmodule YouWeb.AdminAuditLive do
  use YouWeb, :live_view

  alias You.Audit.Streamer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, :refresh)
    {:ok, assign(socket, events: Streamer.recent())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, events: Streamer.recent())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, events: Streamer.recent())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab="audit">
      <:side_panel>
        <div class="text-[11px] font-medium text-muted-foreground uppercase tracking-widest">
          Audit Log
        </div>
        <div class="text-xs text-muted-foreground leading-relaxed">
          Recent security events on this instance. In-memory and capped — configure an
          audit webhook under Settings for durable retention.
        </div>
        <div class="mt-auto pt-4 border-t border-border">
          <.button variant="outline" size="sm" class="w-full justify-center" phx-click="refresh">
            Refresh
          </.button>
        </div>
      </:side_panel>

      <div class="space-y-6">
        <h2 class="text-xl font-medium tracking-tight">Audit Log</h2>

        <p :if={@events == []} class="text-sm text-muted-foreground">
          No audit events recorded yet.
        </p>

        <.table :if={@events != []} id="audit" rows={@events}>
          <:col :let={e} label="Event"><.badge variant="neutral">{e.event}</.badge></:col>
          <:col :let={e} label="Details">
            <span class="text-xs text-muted-foreground font-mono break-all">
              {format_metadata(e.metadata)}
            </span>
          </:col>
          <:col :let={e} label="At">
            <span class="text-xs text-muted-foreground">{e.at}</span>
          </:col>
        </.table>
      </div>
    </Layouts.app>
    """
  end

  defp format_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
  end

  defp format_metadata(_), do: ""
end
