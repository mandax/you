defmodule YouWeb.AppLive.New do
  @moduledoc """
  App registration at `/console/apps/new`.

  A page rather than the dialog this replaces (#130): creation mints a
  client secret shown exactly once, and a dialog that closes on a stray
  click is a bad place for the only copy of a credential. One well-grouped
  form is enough here — nothing about registering an app needs more than
  one context, so this does not follow the tab convention `AppLive.Show`
  uses for its five.

  On success this redirects to the created app's page (`AppLive.Show`),
  carrying the secret across the navigation as a one-shot flash entry so it
  renders from the same credentials-tab dialog a rotated secret uses,
  rather than a parallel one here.
  """
  use YouWeb, :live_view

  import YouWeb.Components.ConsoleChrome

  alias You.Admin
  alias You.Admin.App

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(nav: nav(), node_name: Node.self(), page_title: "Register app")
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
    {:noreply,
     socket
     |> put_flash(:new_app_secret, secret)
     |> push_navigate(to: ~p"/console/apps/#{app.slug}")}
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
            A client secret is generated and shown once, on the app's page, after creation.
          </p>
        </div>

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
                name={@form[:brand_color].name}
                value={@form[:brand_color].value}
                label="Brand color (optional)"
              />
            </div>

            <div class="flex justify-end">
              <.button type="submit">Create</.button>
            </div>
          </.form>
        </.panel>
      </div>

      <Layouts.flash_group flash={@flash} />
    </.console_shell>
    """
  end
end
