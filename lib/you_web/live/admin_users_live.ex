defmodule YouWeb.AdminUsersLive do
  use YouWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :users, [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab="users"
      user_count={0}
      app_count={0}
    >
      <:side_panel>
        <div class="text-[11px] font-medium text-base-content/40 uppercase tracking-widest">
          Filters
        </div>
        <a href="#" class="text-sm text-base-content/60 hover:text-base-content transition-colors">
          All Users
        </a>
        <a href="#" class="text-sm text-base-content/60 hover:text-base-content transition-colors">
          Active
        </a>
        <a href="#" class="text-sm text-base-content/60 hover:text-base-content transition-colors">
          Pending
        </a>
        <a href="#" class="text-sm text-base-content/60 hover:text-base-content transition-colors">
          Blocked
        </a>
        <div class="mt-auto pt-4 border-t border-base-300">
          <button class="btn btn-soft btn-sm w-full justify-center">+ Invite User</button>
        </div>
      </:side_panel>

      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <h2 class="text-xl font-medium tracking-tight">Users</h2>
          <input
            type="search"
            placeholder="Search users..."
            class="input input-sm max-w-56"
          />
        </div>

        <.table id="users" rows={@users}>
          <:col :let={_user} label="Email">—</:col>
          <:col :let={_user} label="Status">—</:col>
          <:col :let={_user} label="Apps">—</:col>
        </.table>
      </div>
    </Layouts.app>
    """
  end
end
