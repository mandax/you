defmodule YouWeb.AppLive.New do
  @moduledoc """
  App registration at `/console/apps/new`.

  A page rather than the dialog this replaces (#130): creation mints a
  client secret shown exactly once, and a dialog that closes on a stray
  click is a bad place for the only copy of a credential. One well-grouped
  form is enough here — nothing about registering an app needs more than
  one context, so this does not follow the tab convention `AppLive.Show`
  uses for its five.

  On success the secret is revealed **on this page**, in place of the form,
  rather than handed off to `AppLive.Show` via a redirect. A redirect would
  have to carry the plaintext across the wire again — through a query
  param, the session, or the flash — and every one of those is a worse
  place for a credential than the connected socket it already lives on.
  The admin gets a link on to the app once they have read it.
  """
  use YouWeb, :live_view

  import YouWeb.Components.ConsoleChrome

  alias You.Admin
  alias You.Admin.App

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(nav: nav(), node_name: Node.self(), page_title: "Register app", created: nil)
     |> assign_form(App.changeset(%App{}, %{}))}
  end

  @impl true
  def handle_event("create_app", %{"app" => params}, socket) do
    params
    |> Map.take([
      "name",
      "slug",
      "callback_url",
      "launch_url",
      "logo_url",
      "brand_color",
      "first_party"
    ])
    |> Admin.create_app()
    |> handle_create(socket)
  end

  defp handle_create({:ok, app, secret}, socket) do
    {:noreply, assign(socket, created: {app, secret})}
  end

  defp handle_create({:error, changeset}, socket) do
    {:noreply, assign_form(socket, changeset)}
  end

  defp assign_form(socket, changeset),
    do: assign(socket, form: to_form(changeset, action: :insert))

  @impl true
  def render(assigns) do
    ~H"""
    <.console_shell nav={@nav} active={app_nav_id()} title="Apps" node_name={@node_name}>
      <div class="space-y-5">
        <div>
          <.link
            navigate={~p"/console/apps"}
            class="font-mono text-xs text-muted-foreground transition-colors hover:text-foreground"
          >
            ← Apps
          </.link>
          <h1 class="mt-1 text-lg font-medium">Register app</h1>
          <p class="max-w-2xl text-sm text-muted-foreground">
            A client secret is generated and shown once, right here, after creation.
          </p>
        </div>

        <.secret_reveal :if={@created} created={@created} />
        <.registration_form :if={!@created} form={@form} />
      </div>

      <Layouts.flash_group flash={@flash} />
    </.console_shell>
    """
  end

  attr :created, :any, required: true

  defp secret_reveal(assigns) do
    {app, secret} = assigns.created
    assigns = assign(assigns, app: app, secret: secret)

    ~H"""
    <.panel
      title="Client secret"
      description="Copy this now. It is hashed at rest and never shown again."
    >
      <div class="max-w-xl space-y-4">
        <div class="rounded-md border border-border bg-background px-3 py-2 font-mono text-xs break-all text-primary">
          {@secret}
        </div>
        <div class="flex items-center justify-between">
          <span class="font-mono text-xs text-muted-foreground">client_id: {@app.slug}</span>
          <.copy_button id="copy-secret" value={@secret} label="Copy secret" />
        </div>
        <p class="text-xs text-muted-foreground">
          This is the only time {@app.name}'s secret is shown. Rotating it later replaces this
          one and shows the new value once, the same way.
        </p>
        <div class="flex justify-end">
          <.link navigate={~p"/console/apps/#{@app.slug}"}>
            <.button>Go to {@app.name}</.button>
          </.link>
        </div>
      </div>
    </.panel>
    """
  end

  attr :form, :map, required: true

  defp registration_form(assigns) do
    ~H"""
    <.panel title="Identity and URLs" description="How the app registers with You.">
      <.form for={@form} id="new-app-form" phx-submit="create_app" class="max-w-xl space-y-4">
        <.input field={@form[:name]} type="text" label="Name" required />
        <.input field={@form[:slug]} type="text" label="Slug (client_id)" required />
        <.input field={@form[:callback_url]} type="url" label="Callback URL" required />
        <.input field={@form[:launch_url]} type="url" label="Launch URL (optional)" />
        <.input field={@form[:first_party]} type="checkbox" label="First-party app" />

        <div class="space-y-4 border-t border-border pt-4">
          <div>
            <h2 class="text-sm font-medium">Branding</h2>
            <p class="mt-1 text-xs text-muted-foreground">
              Shown on You's login page. Everything here can be changed later.
            </p>
          </div>
          <.input field={@form[:logo_url]} type="url" label="Logo URL (optional)" />
          <.color_input
            id="new-app-brand-color"
            field={@form[:brand_color]}
            label="Brand color (optional)"
          />
        </div>

        <div class="flex justify-end">
          <.button type="submit">Create</.button>
        </div>
      </.form>
    </.panel>
    """
  end
end
