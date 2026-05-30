defmodule YouWeb.AdminAuditLive do
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :events, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab="audit">
      <:side_panel>
        <div class="text-[11px] font-medium text-base-content/40 uppercase tracking-widest">
          Audit Log
        </div>
        <div class="text-xs text-base-content/50 leading-relaxed">
          Track all changes made across your You instance.
        </div>
      </:side_panel>

      <div class="space-y-6">
        <h2 class="text-xl font-medium tracking-tight">Audit Log</h2>
        <p class="text-sm text-base-content/50">No audit events recorded yet.</p>
      </div>
    </Layouts.app>
    """
  end
end
