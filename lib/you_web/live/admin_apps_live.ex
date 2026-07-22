defmodule YouWeb.AdminAppsLive do
  use YouWeb, :live_view

  alias You.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_apps(socket) |> assign(new_secret: nil, secret_app: nil)}
  end

  @impl true
  def handle_event("create_app", params, socket) do
    attrs = Map.take(params, ["name", "slug", "callback_url"])

    case Admin.create_app(attrs) do
      {:ok, app, secret} ->
        {:noreply,
         socket
         |> load_apps()
         |> assign(new_secret: secret, secret_app: app)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create app: #{errors(changeset)}")}
    end
  end

  @impl true
  def handle_event("rotate_secret", %{"id" => id}, socket) do
    app = Admin.get_app!(id)

    case Admin.rotate_app_secret(app) do
      {:ok, app, secret} ->
        {:noreply, assign(socket, new_secret: secret, secret_app: app)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not rotate secret: #{errors(changeset)}")}
    end
  end

  @impl true
  def handle_event("delete_app", %{"id" => id}, socket) do
    id |> Admin.get_app!() |> Admin.delete_app()
    {:noreply, socket |> load_apps() |> put_flash(:info, "App deleted.")}
  end

  @impl true
  def handle_event("dismiss_secret", _params, socket) do
    {:noreply, assign(socket, new_secret: nil, secret_app: nil)}
  end

  defp load_apps(socket) do
    apps = Admin.list_apps()
    assign(socket, apps: apps, app_count: length(apps))
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map(fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      active_tab="apps"
      app_count={@app_count}
    >
      <:side_panel>
        <div class="text-[11px] font-medium text-muted-foreground uppercase tracking-widest">Apps</div>
        <div class="text-xs text-muted-foreground leading-relaxed">
          OAuth &amp; machine-to-machine clients that authenticate against this instance.
        </div>
        <div class="mt-auto pt-4 border-t border-border">
          <.dialog id="new-app">
            <:trigger>
              <.button variant="outline" size="sm" class="w-full justify-center">+ New App</.button>
            </:trigger>
            <:title>Register app</:title>
            <:description>A client secret is generated and shown once on creation.</:description>
            <form phx-submit="create_app" class="space-y-4">
              <.input type="text" name="name" label="Name" value="" required />
              <.input type="text" name="slug" label="Slug (client_id)" value="" required />
              <.input type="url" name="callback_url" label="Callback URL" value="" required />
              <div class="flex justify-end">
                <.button type="submit">Create</.button>
              </div>
            </form>
          </.dialog>
        </div>
      </:side_panel>

      <div class="space-y-6">
        <h2 class="text-xl font-medium tracking-tight">Apps</h2>

        <p :if={@apps == []} class="text-sm text-muted-foreground">
          No apps configured yet. Use “New App” to register one.
        </p>

        <.table :if={@apps != []} id="apps" rows={@apps}>
          <:col :let={app} label="Name">{app.name}</:col>
          <:col :let={app} label="Client ID"><code class="text-xs">{app.slug}</code></:col>
          <:col :let={app} label="Callback">
            <span class="text-xs text-muted-foreground">{app.callback_url}</span>
          </:col>
          <:col :let={app} label="Secret">
            <.badge variant={if app.client_secret_hash, do: "success", else: "neutral"}>
              {if app.client_secret_hash, do: "set", else: "none"}
            </.badge>
          </:col>
          <:action :let={app}>
            <.button variant="ghost" size="xs" phx-click="rotate_secret" phx-value-id={app.id}>
              Rotate
            </.button>
            <.button
              variant="ghost"
              size="xs"
              class="text-destructive"
              phx-click="delete_app"
              phx-value-id={app.id}
              data-confirm={"Delete app “#{app.name}”? This cannot be undone."}
            >
              Delete
            </.button>
          </:action>
        </.table>
      </div>

      <.dialog id="app-secret" open={@new_secret != nil} on_close="dismiss_secret">
        <:title>Client secret</:title>
        <:description>
          Copy this now — it is hashed at rest and will never be shown again.
        </:description>
        <div :if={@new_secret} class="space-y-4">
          <div class="rounded-md border border-border bg-muted/40 p-3 font-mono text-xs break-all">
            {@new_secret}
          </div>
          <div class="flex items-center justify-between">
            <span :if={@secret_app} class="text-xs text-muted-foreground">
              client_id: <code>{@secret_app.slug}</code>
            </span>
            <.copy_button id="copy-secret" value={@new_secret} label="Copy secret" />
          </div>
        </div>
        <:footer>
          <.button variant="outline" phx-click="dismiss_secret">Done</.button>
        </:footer>
      </.dialog>
    </Layouts.app>
    """
  end
end
