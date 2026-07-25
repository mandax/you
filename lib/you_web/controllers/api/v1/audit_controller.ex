defmodule YouWeb.API.V1.AuditController do
  use YouWeb, :controller

  alias You.Audit.Streamer

  def index(conn, _params) do
    json(conn, %{data: Streamer.recent()})
  end
end
