defmodule YouWeb.UserDashboardHTML do
  use YouWeb, :html

  embed_templates "user_dashboard_html/*"

  @doc "Where an app card sends the user."
  defdelegate launch_target(app), to: You.Admin.App

  @doc "First letter of the app name, for the card's avatar tile."
  def initial(name) when is_binary(name) and name != "", do: String.upcase(String.at(name, 0))
  def initial(_), do: "•"
end
