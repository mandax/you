defmodule YouWeb.EndpointCheckOriginTest do
  @moduledoc """
  `check_origin` was `false` in dev and unset (defaulting to a canonical-only
  check) everywhere else — either way, a WebSocket handshake from an app
  host would be rejected once #121 puts a login page there, in the
  confusing way described in the #121 review: static markup renders, the
  LiveView socket just never connects.

  `You.Hosting.check_origin?/1` is exactly the function Phoenix invokes for
  every handshake (`Phoenix.Socket.Transport.check_origin/5` calls
  `apply(module, function, [origin_uri | args])`), and is unit-tested
  directly in `test/you/hosting_test.exs`. This file pins the other half:
  that the endpoint is actually wired to call it, not a static list and
  never `false`.
  """

  use ExUnit.Case, async: true

  test "the endpoint's check_origin is the shared You.Hosting predicate, not false or a static list" do
    assert YouWeb.Endpoint.config(:check_origin) == {You.Hosting, :check_origin?, []}
  end

  test "never false — that would disable CSWSH protection outright" do
    refute YouWeb.Endpoint.config(:check_origin) == false
  end
end
