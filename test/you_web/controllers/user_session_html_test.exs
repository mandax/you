defmodule YouWeb.UserSessionHTMLTest do
  @moduledoc """
  Unit coverage for `social_auth_href/2`, the #121/#132 handoff: on the
  canonical host the social button still reads this page's own session
  (`nil` ctx, relative link); off canonical it has to reach
  `/auth/:provider` on canonical explicitly, carrying `ctx` — see
  `UserSessionController.social_ctx/1` for why (the upstream provider's
  registered `redirect_uri` is canonical-only).
  """

  use ExUnit.Case, async: true

  alias YouWeb.UserSessionHTML

  describe "social_auth_href/2 with no ctx (canonical host)" do
    test "is a bare relative path" do
      assert UserSessionHTML.social_auth_href("google", nil) == "/auth/google"
    end
  end

  describe "social_auth_href/2 with a ctx (off canonical)" do
    test "is an absolute URL on the canonical host, carrying ctx as a query param" do
      href = UserSessionHTML.social_auth_href("google", "signed-ctx-blob")

      uri = URI.parse(href)
      assert uri.host == YouWeb.Endpoint.host()
      assert uri.path == "/auth/google"
      assert URI.decode_query(uri.query) == %{"ctx" => "signed-ctx-blob"}
    end
  end
end
