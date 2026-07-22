defmodule YouWeb.AdminUsersLive do
  use YouWeb, :live_view

  alias You.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_users(socket)}
  end

  @impl true
  def handle_event("promote", %{"id" => id}, socket) do
    Admin.get_user!(id) |> Admin.promote_admin()
    {:noreply, socket |> load_users() |> put_flash(:info, "User promoted to admin.")}
  end

  @impl true
  def handle_event("demote", %{"id" => id}, socket) do
    Admin.get_user!(id) |> Admin.demote_admin()
    {:noreply, socket |> load_users() |> put_flash(:info, "Admin rights revoked.")}
  end

  defp load_users(socket) do
    rows = Admin.list_users_with_stats()
    assign(socket, rows: rows, user_count: length(rows))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab="users"
      user_count={@user_count}
    >
      <:side_panel>
        <div class="text-[11px] font-medium text-muted-foreground uppercase tracking-widest">
          Users
        </div>
        <div class="text-xs text-muted-foreground leading-relaxed">
          Everyone with an account on this instance, including federated and passkey sign-ins.
        </div>
      </:side_panel>

      <div class="space-y-6">
        <h2 class="text-xl font-medium tracking-tight">Users</h2>

        <p :if={@rows == []} class="text-sm text-muted-foreground">No users yet.</p>

        <.table :if={@rows != []} id="users" rows={@rows}>
          <:col :let={row} label="Email">{row.user.email}</:col>
          <:col :let={row} label="Status">
            <.badge variant={if row.user.confirmed_at, do: "success", else: "warning"}>
              {if row.user.confirmed_at, do: "confirmed", else: "pending"}
            </.badge>
          </:col>
          <:col :let={row} label="Role">
            <.badge variant={if row.user.is_admin, do: "info", else: "neutral"}>
              {if row.user.is_admin, do: "admin", else: "user"}
            </.badge>
          </:col>
          <:col :let={row} label="Passkeys">{row.passkeys}</:col>
          <:col :let={row} label="Federated">{row.identities}</:col>
          <:action :let={row}>
            <.button
              :if={!row.user.is_admin}
              variant="ghost"
              size="xs"
              phx-click="promote"
              phx-value-id={row.user.id}
            >
              Make admin
            </.button>
            <.button
              :if={row.user.is_admin && row.user.id != @current_scope.user.id}
              variant="ghost"
              size="xs"
              class="text-destructive"
              phx-click="demote"
              phx-value-id={row.user.id}
            >
              Revoke admin
            </.button>
          </:action>
        </.table>
      </div>
    </Layouts.app>
    """
  end
end
