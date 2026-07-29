defmodule YouWeb.Components.LoginChrome do
  @moduledoc """
  The branded part of the login page.

  Rendered both by the real login template and by the console's branding
  preview, so what an admin previews is the markup users get rather than a
  mockup that drifts.
  """
  use Phoenix.Component

  @doc """
  App-branded login header: logo (or a lock placeholder) above a heading that
  tints the app name with the brand color.

  `app_name` nil renders nothing — the unbranded login page uses its own
  wordmark header instead.

  `headline` and `subtitle` replace the default copy ("Sign in to continue
  to <app>" / "secured by You") wholesale when set, so an admin can write
  copy that doesn't fit that template.
  """
  attr :app_name, :string, default: nil
  attr :logo_url, :string, default: nil
  attr :brand_color, :string, default: nil
  attr :headline, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :accent_color, :string, default: nil
  attr :brand_color_dark, :string, default: nil
  attr :accent_color_dark, :string, default: nil

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
        <%= if @headline do %>
          {@headline}
        <% else %>
          Sign in to continue to
          <span :if={@brand_color} class="dark:hidden" style={"color: #{@brand_color}"}>
            {@app_name}
          </span>
          <span
            :if={@brand_color}
            class="hidden dark:inline"
            style={"color: #{@brand_color_dark || @brand_color}"}
          >
            {@app_name}
          </span>
          <span :if={!@brand_color} class="text-primary">{@app_name}</span>
        <% end %>
      </h1>
      <p
        class={["mt-1 text-sm text-muted-foreground", @accent_color && "dark:hidden"]}
        style={@accent_color && "color: #{@accent_color}"}
      >
        {@subtitle || "secured by You"}
      </p>
      <p
        :if={@accent_color}
        class="mt-1 hidden text-sm text-muted-foreground dark:block"
        style={"color: #{@accent_color_dark || @accent_color}"}
      >
        {@subtitle || "secured by You"}
      </p>
    </div>
    """
  end

  @doc """
  Inert rendering of the login form's controls, for the console preview.

  Deliberately not the real form: that one carries CSRF, a live action and
  passkey wiring, none of which belong in a preview pane. What it does share is
  the brand hooks (`data-brand-bg`, `data-brand-text`) and the method list, so
  an admin sees the branding land on the same controls a user will see.
  """
  attr :methods, :list, required: true
  attr :providers, :list, default: []

  def login_form_preview(assigns) do
    ~H"""
    <div class="pointer-events-none mt-6 space-y-4 text-left select-none" aria-hidden="true">
      <div :if={"password" in @methods} class="space-y-4">
        <div>
          <span class="mb-1 block text-sm font-medium text-foreground">Email</span>
          <div class="h-10 w-full rounded-md border border-input bg-background" />
        </div>
        <div>
          <span class="mb-1 block text-sm font-medium text-foreground">Password</span>
          <div class="h-10 w-full rounded-md border border-input bg-background" />
        </div>
        <div class="flex items-center justify-between text-sm">
          <span class="text-muted-foreground">Stay logged in</span>
          <span class="font-medium text-foreground" data-brand-text>Forgot password?</span>
        </div>
        <div
          class="flex h-11 w-full items-center justify-center rounded-md bg-primary text-sm font-medium text-primary-foreground"
          data-brand-bg
        >
          Log in
        </div>
      </div>

      <div
        :if={"password" in @methods and "magic_link" in @methods}
        class="flex items-center gap-3 text-sm text-muted-foreground"
      >
        <span class="flex-1 border-t border-border" /> <span>or</span>
        <span class="flex-1 border-t border-border" />
      </div>

      <div
        :if={"magic_link" in @methods}
        class="flex h-10 w-full items-center justify-center rounded-md border border-input text-sm font-medium"
      >
        Email me a magic link
      </div>

      <div :if={"social" in @methods} class="space-y-3">
        <div
          :for={provider <- @providers}
          class="flex h-10 w-full items-center justify-center rounded-md border border-input text-sm font-medium"
        >
          Sign in with {provider}
        </div>
      </div>

      <div
        :if={"passkey" in @methods}
        class="flex h-10 w-full items-center justify-center gap-2 rounded-md border border-input text-sm font-medium"
      >
        <span class="lucide-fingerprint-pattern size-4" /> Sign in with a passkey
      </div>
    </div>
    """
  end
end
