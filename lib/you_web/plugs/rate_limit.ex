defmodule YouWeb.Plugs.RateLimit do
  @moduledoc """
  Rate-limits credential-verifying endpoints with a fixed window per
  remote IP.

      plug YouWeb.Plugs.RateLimit, key: :login

  Limits are read at request time so operators can tune them in
  `runtime.exs` without recompiling:

      config :you, YouWeb.RateLimit, %{login: {5, 60_000}}

  Keys without a configured limit pass through. When the limit is
  exceeded the request is halted with 429 and a `Retry-After` header.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    key = Keyword.fetch!(opts, :key)

    case YouWeb.RateLimit.limit_for(key) do
      nil ->
        conn

      {limit, window_ms} ->
        bucket = {key, client_ip(conn)}

        case YouWeb.RateLimit.check(bucket, limit, window_ms) do
          {:allow, _count} ->
            conn

          {:deny, retry_after_ms} ->
            retry_after = max(ceil(retry_after_ms / 1_000), 1)

            conn
            |> put_resp_header("retry-after", Integer.to_string(retry_after))
            |> respond()
            |> halt()
        end
    end
  end

  defp respond(conn) do
    if conn.private[:phoenix_format] == "json" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(429, "Too many requests. Please try again later.")
    end
  end

  # You is deployed behind a reverse proxy (see docs/ops/deploy.md), so the
  # real client address arrives in X-Forwarded-For. If the app is exposed
  # directly, clients can spoof that header to dodge the limit, so don't.
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [header | _] -> header |> String.split(",", parts: 2) |> hd() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
