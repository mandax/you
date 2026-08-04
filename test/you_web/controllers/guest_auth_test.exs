defmodule YouWeb.GuestAuthTest do
  @moduledoc """
  The HTTP surface for anonymous accounts: create one, use it, and turn it
  into a real account without the user id changing under the app's feet.
  """
  use YouWeb.ConnCase, async: false

  alias You.AccountsFixtures
  alias You.Settings

  setup do
    {:ok, app, secret} =
      You.Admin.create_app(%{
        slug: "guest-app",
        name: "Guest App",
        callback_url: "https://guest.example.com/cb",
        first_party: true
      })

    Settings.set(:feature_guest_login, true)

    %{app: app, secret: secret}
  end

  defp guest!(ctx) do
    conn =
      post(build_conn(), ~p"/api/auth/guest", %{
        "client_id" => ctx.app.slug,
        "client_secret" => ctx.secret
      })

    json_response(conn, 201)
  end

  describe "POST /api/auth/guest" do
    test "returns a token bundle whose JWT says guest", ctx do
      body = guest!(ctx)

      assert {:ok, claims} = You.JWT.verify(body["access_token"])
      assert claims["guest"] == true
      assert claims["sub"] == body["user"]["id"]
      assert is_binary(body["refresh_token"])
    end

    test "is refused when the instance has not switched guests on", ctx do
      Settings.set(:feature_guest_login, false)

      conn =
        post(build_conn(), ~p"/api/auth/guest", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret
        })

      assert %{"error" => "guests_disabled"} = json_response(conn, 403)
    end

    test "is refused for a third-party app", _ctx do
      {:ok, third, third_secret} =
        You.Admin.create_app(%{
          slug: "third",
          name: "Third",
          callback_url: "https://third.example.com/cb"
        })

      conn =
        post(build_conn(), ~p"/api/auth/guest", %{
          "client_id" => third.slug,
          "client_secret" => third_secret
        })

      assert %{"error" => "unauthorized_client"} = json_response(conn, 403)
    end

    test "is refused with a wrong client secret", ctx do
      conn =
        post(build_conn(), ~p"/api/auth/guest", %{
          "client_id" => ctx.app.slug,
          "client_secret" => "nope"
        })

      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end
  end

  describe "POST /api/auth/upgrade" do
    test "keeps the user id and drops the guest claim", ctx do
      guest = guest!(ctx)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
        |> post(~p"/api/auth/upgrade", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => "person@example.com",
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"access_token" => jwt, "user" => user} = json_response(conn, 200)
      assert user["id"] == guest["user"]["id"]
      assert user["email"] == "person@example.com"

      assert {:ok, claims} = You.JWT.verify(jwt)
      refute Map.has_key?(claims, "guest")
    end

    test "the upgraded account can then log in normally", ctx do
      guest = guest!(ctx)

      build_conn()
      |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
      |> post(~p"/api/auth/upgrade", %{
        "client_id" => ctx.app.slug,
        "client_secret" => ctx.secret,
        "email" => "person@example.com",
        "password" => AccountsFixtures.valid_user_password()
      })

      conn =
        post(build_conn(), ~p"/api/auth/login", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => "person@example.com",
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"user" => user} = json_response(conn, 200)
      assert user["id"] == guest["user"]["id"]
    end

    test "accepts the guest token as a parameter when Basic carries client auth", ctx do
      guest = guest!(ctx)
      basic = "Basic " <> Base.encode64("#{ctx.app.slug}:#{ctx.secret}")

      conn =
        build_conn()
        |> put_req_header("authorization", basic)
        |> post(~p"/api/auth/upgrade", %{
          "access_token" => guest["access_token"],
          "email" => "person@example.com",
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"user" => user} = json_response(conn, 200)
      assert user["id"] == guest["user"]["id"]
    end

    test "a request with no guest token is refused", ctx do
      conn =
        post(build_conn(), ~p"/api/auth/upgrade", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => "person@example.com",
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "a real account's token cannot be upgraded", ctx do
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      login =
        post(build_conn(), ~p"/api/auth/login", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => user.email,
          "password" => AccountsFixtures.valid_user_password()
        })
        |> json_response(200)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{login["access_token"]}")
        |> post(~p"/api/auth/upgrade", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => "someone-else@example.com",
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"error" => "not_a_guest"} = json_response(conn, 409)
    end

    test "an email already in use is refused", ctx do
      existing = AccountsFixtures.user_fixture()
      guest = guest!(ctx)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{guest["access_token"]}")
        |> post(~p"/api/auth/upgrade", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => existing.email,
          "password" => AccountsFixtures.valid_user_password()
        })

      assert %{"error" => "email_taken"} = json_response(conn, 409)
    end
  end
end
