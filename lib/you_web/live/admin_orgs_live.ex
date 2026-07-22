defmodule YouWeb.AdminOrgsLive do
  use YouWeb, :live_view

  alias You.{Organizations, Accounts, Admin}

  @roles ~w(owner admin member)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(selected: nil, members: [], roles: @roles) |> load_orgs()}
  end

  @impl true
  def handle_event("create_org", params, socket) do
    attrs = Map.take(params, ["name", "slug"])

    case Organizations.create_organization(attrs) do
      {:ok, _org} ->
        {:noreply, socket |> load_orgs() |> put_flash(:info, "Organization created.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create org: #{errors(changeset)}")}
    end
  end

  @impl true
  def handle_event("select_org", %{"id" => id}, socket) do
    {:noreply, select(socket, id)}
  end

  @impl true
  def handle_event("add_member", %{"email" => email, "role" => role}, socket) do
    org = socket.assigns.selected

    case Accounts.get_user_by_email(email) do
      nil ->
        {:noreply, put_flash(socket, :error, "No user with email #{email}.")}

      user ->
        case Organizations.add_member(org, user, role) do
          {:ok, _} ->
            {:noreply, socket |> select(org.id) |> put_flash(:info, "Member added.")}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, "Could not add member: #{errors(changeset)}")}
        end
    end
  end

  @impl true
  def handle_event("update_role", %{"user_id" => uid, "role" => role}, socket) do
    org = socket.assigns.selected
    Organizations.update_member_role(org, Admin.get_user!(uid), role)
    {:noreply, select(socket, org.id)}
  end

  @impl true
  def handle_event("remove_member", %{"user_id" => uid}, socket) do
    org = socket.assigns.selected
    Organizations.remove_member(org, Admin.get_user!(uid))
    {:noreply, socket |> select(org.id) |> put_flash(:info, "Member removed.")}
  end

  defp select(socket, id) do
    case Organizations.get_organization(id) do
      nil -> assign(socket, selected: nil, members: [])
      org -> assign(socket, selected: org, members: Organizations.list_members(org))
    end
  end

  defp load_orgs(socket) do
    assign(socket, orgs: Organizations.list_organizations_with_counts())
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_tab="orgs">
      <:side_panel>
        <div class="text-[11px] font-medium text-muted-foreground uppercase tracking-widest">
          Organizations
        </div>
        <button
          :for={{org, count} <- @orgs}
          type="button"
          phx-click="select_org"
          phx-value-id={org.id}
          class={[
            "flex items-center justify-between text-left text-sm rounded-md px-2 py-1.5 transition-colors",
            if(@selected && @selected.id == org.id,
              do: "bg-muted text-foreground",
              else: "text-muted-foreground hover:text-foreground hover:bg-muted/50"
            )
          ]}
        >
          <span class="truncate">{org.name}</span>
          <span class="text-[10px] px-1.5 py-0.5 rounded-full bg-muted text-muted-foreground">
            {count}
          </span>
        </button>
        <div class="mt-auto pt-4 border-t border-border">
          <.dialog id="new-org">
            <:trigger>
              <.button variant="outline" size="sm" class="w-full justify-center">+ New Org</.button>
            </:trigger>
            <:title>Create organization</:title>
            <form phx-submit="create_org" class="space-y-4">
              <.input type="text" name="name" label="Name" value="" required />
              <.input type="text" name="slug" label="Slug" value="" required />
              <div class="flex justify-end">
                <.button type="submit">Create</.button>
              </div>
            </form>
          </.dialog>
        </div>
      </:side_panel>

      <div :if={@selected == nil} class="space-y-6">
        <h2 class="text-xl font-medium tracking-tight">Organizations</h2>
        <p :if={@orgs == []} class="text-sm text-muted-foreground">
          No organizations yet. Use “New Org” to create one.
        </p>
        <p :if={@orgs != []} class="text-sm text-muted-foreground">
          Select an organization to manage its members.
        </p>
      </div>

      <div :if={@selected} class="space-y-6">
        <div>
          <h2 class="text-xl font-medium tracking-tight">{@selected.name}</h2>
          <p class="text-sm text-muted-foreground">
            <code class="text-xs">{@selected.slug}</code>
          </p>
        </div>

        <section class="space-y-4">
          <h3 class="text-sm font-medium">Add member</h3>
          <form phx-submit="add_member" class="flex items-end gap-2">
            <div class="flex-1">
              <.input type="email" name="email" label="User email" value="" required />
            </div>
            <.input
              type="select"
              name="role"
              label="Role"
              value="member"
              options={Enum.map(@roles, &{String.capitalize(&1), &1})}
            />
            <.button type="submit">Add</.button>
          </form>
        </section>

        <.table :if={@members != []} id="members" rows={@members}>
          <:col :let={{user, _role}} label="Email">{user.email}</:col>
          <:col :let={{user, role}} label="Role">
            <form phx-change="update_role" class="inline-flex">
              <input type="hidden" name="user_id" value={user.id} />
              <select
                name="role"
                class="h-8 rounded-md border border-input bg-background px-2 text-sm"
              >
                <option :for={r <- @roles} value={r} selected={r == role}>
                  {String.capitalize(r)}
                </option>
              </select>
            </form>
          </:col>
          <:action :let={{user, _role}}>
            <.button
              variant="ghost"
              size="xs"
              class="text-destructive"
              phx-click="remove_member"
              phx-value-user_id={user.id}
            >
              Remove
            </.button>
          </:action>
        </.table>
        <p :if={@members == []} class="text-sm text-muted-foreground">No members yet.</p>
      </div>
    </Layouts.app>
    """
  end
end
