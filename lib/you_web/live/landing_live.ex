defmodule YouWeb.LandingLive do
  @moduledoc """
  Public landing page.
  """
  use YouWeb, :live_view

  @description "You is a free, self-hosted identity and access management service: " <>
                 "OIDC login, 2FA, passkeys, per-app roles, a management console and an " <>
                 "audit trail, in one container. MIT licensed, with in-cluster RPC for " <>
                 "Elixir apps."

  @impl true
  def mount(_params, _session, socket) do
    socket
    |> assign(:page_title, "Self-hosted identity, standard OIDC")
    |> assign(:page_description, @description)
    # The instance's own base URL: canonical has to follow PHX_HOST rather than
    # be baked in, or every deployment claims the same canonical page.
    |> assign(:canonical_url, YouWeb.Endpoint.url() <> "/")
    |> assign(:structured_data, structured_data())
    |> then(&{:ok, &1})
  end

  # Schema.org SoftwareApplication: the one type a search engine can actually
  # do something with here (name, license, price, what it runs on).
  defp structured_data do
    Jason.encode!(%{
      "@context" => "https://schema.org",
      "@type" => "SoftwareApplication",
      "name" => "You",
      "description" => @description,
      "applicationCategory" => "SecurityApplication",
      "applicationSubCategory" => "Identity and Access Management",
      "operatingSystem" => "Linux, Docker",
      "url" => YouWeb.Endpoint.url() <> "/",
      "codeRepository" => "https://github.com/mandax/you",
      "license" => "https://opensource.org/licenses/MIT",
      "isAccessibleForFree" => true,
      "offers" => %{
        "@type" => "Offer",
        "price" => "0",
        "priceCurrency" => "USD"
      },
      "author" => %{
        "@type" => "Person",
        "name" => "Anderson F. Pinto"
      }
    })
  end
end
