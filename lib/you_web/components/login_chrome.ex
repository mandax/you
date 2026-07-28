defmodule YouWeb.Components.LoginChrome do
  @moduledoc """
  The branded part of the login page.

  Rendered both by the real login template and by the console's branding
  preview, so what an operator previews is the markup users get rather than a
  mockup that drifts.
  """
  use Phoenix.Component

  @doc """
  App-branded login header: logo (or a lock placeholder) above a heading that
  tints the app name with the brand color.

  `app_name` nil renders nothing — the unbranded login page uses its own
  wordmark header instead.
  """
  attr :app_name, :string, default: nil
  attr :logo_url, :string, default: nil
  attr :brand_color, :string, default: nil

  def login_header(assigns) do
    ~H"""
    <div :if={@app_name}>
      <img
        :if={@logo_url}
        src={@logo_url}
        alt={@app_name}
        class="mx-auto mb-4 size-11 rounded-xl border border-border object-cover"
      />
      <div
        :if={!@logo_url}
        class="mx-auto mb-4 flex size-11 items-center justify-center rounded-xl border border-border"
      >
        <span class="lucide-lock block size-5 text-muted-foreground" />
      </div>
      <h1 class="text-2xl font-bold tracking-tight">
        Sign in to continue to
        <span :if={@brand_color} style={"color: #{@brand_color}"}>{@app_name}</span>
        <span :if={!@brand_color} class="text-primary">{@app_name}</span>
      </h1>
      <p class="mt-1 text-sm text-muted-foreground">secured by You</p>
    </div>
    """
  end
end
