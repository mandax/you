defmodule YouWeb.UserDashboardHTML do
  use YouWeb, :html

  embed_templates "user_dashboard_html/*"

  @doc """
  Where an app card sends the user. Prefers the app's configured `launch_url`;
  otherwise falls back to the origin of its callback URL.
  """
  def launch_target(%{launch_url: url}) when is_binary(url) and url != "", do: url
  def launch_target(%{callback_url: cb}) when is_binary(cb), do: origin(cb)
  def launch_target(_), do: "#"

  defp origin(url) do
    uri = URI.parse(url)
    port = if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""
    "#{uri.scheme}://#{uri.host}#{port}/"
  end

  @doc "First letter of the app name, for the card's avatar tile."
  def initial(name) when is_binary(name) and name != "", do: String.upcase(String.at(name, 0))
  def initial(_), do: "•"
end
