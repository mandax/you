defmodule YouWeb.Components.SiteChrome do
  @moduledoc """
  Shared public-site chrome: the wordmark, the marketing nav, and the footer.

  Landing and Docs both render these, so they live in one place. Nav anchors are
  absolute (`/#security`) so they resolve from any page, not just the landing.
  """
  use Phoenix.Component
  use YouWeb, :verified_routes

  import YouWeb.Components.Base.Button

  def wordmark(assigns) do
    ~H"""
    <.link navigate={~p"/"} class="flex items-center gap-2 font-semibold">
      <span class="grid h-7 w-7 place-items-center rounded-md bg-primary text-primary-foreground">
        <span class="lucide-key-round size-4 block" />
      </span>
      <span class="font-mono tracking-tight">
        you <span class="text-azure-brand">//</span>
      </span>
    </.link>
    """
  end

  attr :button, :any, required: false, default: nil

  def site_nav(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-border bg-background/80 backdrop-blur">
      <div class="mx-auto flex h-14 max-w-6xl items-center justify-between px-5">
        <.wordmark />
        <nav class="hidden items-center gap-6 text-sm text-muted-foreground md:flex">
          <.link href="/#security" class="hover:text-foreground">Security</.link>
          <.link href="/#comparison" class="hover:text-foreground">Compare</.link>
          <.link href="/#pricing" class="hover:text-foreground">Self-host</.link>
          <.link href="/#faq" class="hover:text-foreground">FAQ</.link>
        </nav>
        <div class="flex items-center gap-2">
          <.button size="sm" href="/#pricing">Self-host You</.button>
        </div>
      </div>
    </header>
    """
  end

  def site_footer(assigns) do
    assigns = assign(assigns, :columns, footer_columns())

    ~H"""
    <footer class="border-t border-border py-14">
      <div class="mx-auto grid max-w-6xl gap-10 px-5 sm:grid-cols-2 md:grid-cols-4">
        <div>
          <.wordmark />
          <p class="mt-3 max-w-xs text-sm text-muted-foreground">
            Self-hosted identity for the BEAM — one login your Elixir apps connect to over Erlang
            distribution.
          </p>
          <div class="mt-3 flex items-center gap-2 font-mono text-xs text-muted-foreground">
            <span class="lucide-server size-3.5 block" /> free community image · v0.1.0
          </div>
        </div>
        <div :for={col <- @columns}>
          <div class="text-sm font-semibold">{col.heading}</div>
          <ul class="mt-3 space-y-2 text-sm text-muted-foreground">
            <li :for={{label, href} <- col.links}>
              <.link href={href} class="hover:text-foreground">{label}</.link>
            </li>
          </ul>
        </div>
      </div>
    </footer>
    """
  end

  defp footer_columns do
    [
      %{
        heading: "Product",
        links: [
          {"Redirect + exchange", "/#security"},
          {"2FA + recovery", "/#security"},
          {"Self-host", "/#pricing"},
          {"Pricing", "/#pricing"}
        ]
      },
      %{
        heading: "Security",
        links: [
          {"Security model", "/#security"},
          {"Audit log", "/#security"},
          {"Revocation", "/#security"},
          {"Compare", "/#comparison"}
        ]
      },
      %{
        heading: "Developers",
        links: [
          {"Docs", "#"},
          {"Status", "#"},
          {"ADRs", "#"},
          {"Contact", "#"}
        ]
      }
    ]
  end
end
