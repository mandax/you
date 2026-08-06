defmodule YouWeb.Plugs.ConsoleLegacyRedirect do
  @moduledoc """
  Redirects the pre-#136 `?view=`/`?tab=` query-string addresses to their
  path equivalents, for one release — an admin's bookmark or a link in
  published docs should still land somewhere rather than error.

  Covers both shapes that existed before #136: the console's own
  `/console?view=x&tab=y` and the app page's `/console/apps/:slug?tab=y`.

  A plug on the `/console` scope rather than a check inside
  `ConsoleLive.handle_params/3`: a request shaped like an old link never
  needs `ConsoleLive.mount/3` — feature flags, providers, the upload
  socket — to be told it is redirecting, and this is meant to be deleted
  outright next release, which is easier done as one file than as logic
  woven into the LiveView it is scaffolding around.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    case legacy_path(conn.path_info, conn.query_params) do
      nil -> conn
      path -> conn |> redirect(to: path) |> halt()
    end
  end

  # `path_info` already drops empty segments, so a trailing slash
  # (`/console/?view=x`) matches the same as `/console?view=x` — no separate
  # case needed for it.
  defp legacy_path(["console"], %{"view" => view} = query) when is_binary(view) do
    build_path(["console", view], query["tab"])
  end

  defp legacy_path(["console", "apps", slug], %{"tab" => tab}) when is_binary(tab) do
    build_path(["console", "apps", slug], tab)
  end

  defp legacy_path(_path_info, _query), do: nil

  defp build_path(segments, tab) when is_binary(tab), do: encode_path(segments ++ [tab])
  defp build_path(segments, _tab), do: encode_path(segments)

  # Percent-encodes each segment on its own rather than trusting the query
  # value verbatim, so a `view` or `tab` containing `/` cannot inject an
  # extra path segment.
  defp encode_path(segments) do
    "/" <>
      Enum.map_join(segments, "/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)
  end
end
