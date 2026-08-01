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
    if You.Settings.enabled?(:feature_landing_page) do
      {:ok, mount_landing(socket)}
    else
      # An instance that is infrastructure for one app has no homepage to
      # show: an admin wants the console, and anyone else wants to sign in.
      {:ok, redirect(socket, to: destination(socket.assigns[:current_scope]))}
    end
  end

  defp destination(%{user: %{is_admin: true}}), do: ~p"/console"
  defp destination(%{user: %{}}), do: ~p"/users/settings"
  defp destination(_), do: ~p"/users/log-in"

  defp mount_landing(socket) do
    socket
    |> assign(:page_title, "Self-hosted identity, standard OIDC")
    |> assign(:page_description, @description)
    # The instance's own base URL: canonical has to follow PHX_HOST rather than
    # be baked in, or every deployment claims the same canonical page.
    |> assign(:canonical_url, YouWeb.Endpoint.url() <> "/")
    |> assign(:structured_data, structured_data())
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
