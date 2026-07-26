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
    <.link navigate={~p"/"} class="flex items-center gap-2">
      <span class="font-mono text-base font-bold tracking-tight text-primary">YOU</span>
    </.link>
    """
  end

  attr :button, :any, required: false, default: nil
  attr :current_scope, :map, default: nil

  def site_nav(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-border bg-background/80 backdrop-blur">
      <div class="mx-auto flex h-14 max-w-6xl items-center justify-between px-5">
        <.wordmark />
        <nav class="hidden items-center gap-6 text-sm text-muted-foreground md:flex">
          <.link href="/#console" class="hover:text-foreground">Console</.link>
          <.link href="/#security" class="hover:text-foreground">Features</.link>
          <.link href="/#comparison" class="hover:text-foreground">Compare</.link>
          <.link href="/#get-started" class="hover:text-foreground">Get started</.link>
        </nav>
        <div class="flex items-center gap-2">
          <button
            id="theme-toggle"
            type="button"
            phx-hook="ThemeToggle"
            aria-label="Toggle dark mode"
            class="rounded-md p-2 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
          >
            <span class="lucide-moon block size-4 dark:hidden" />
            <span class="lucide-sun hidden size-4 dark:block" />
          </button>
          <.button :if={@current_scope} size="sm" navigate={~p"/users/dashboard"}>Dashboard</.button>
          <.button
            :if={!@current_scope}
            size="sm"
            variant="outline"
            href="https://github.com/mandax/you"
          >
            GitHub repo
          </.button>
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
            Self-hosted identity, standard OIDC. One login for every service you run.
          </p>
          <div class="mt-3 flex items-center gap-2 font-mono text-xs text-muted-foreground">
            <span class="lucide-server size-3.5 block" /> free · v0.1.0
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
          {"The console", "/#console"},
          {"Features", "/#security"},
          {"Compare", "/#comparison"},
          {"Get started", "/#get-started"}
        ]
      },
      %{
        heading: "Docs",
        links: [
          {"Integration guide", "https://github.com/mandax/you/blob/main/docs/integration.md"},
          {"Deployment", "https://github.com/mandax/you/blob/main/docs/ops/deploy.md"},
          {"REST API", "https://github.com/mandax/you/blob/main/docs/api.md"},
          {"Webhooks", "https://github.com/mandax/you/blob/main/docs/webhooks.md"}
        ]
      },
      %{
        heading: "Project",
        links: [
          {"GitHub", "https://github.com/mandax/you"},
          {"MIT License", "https://github.com/mandax/you/blob/main/LICENSE"}
        ]
      }
    ]
  end
end
