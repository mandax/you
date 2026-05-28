defmodule YouWeb.PageController do
  use YouWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
