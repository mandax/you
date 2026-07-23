defmodule YouWeb.HeadlessAuthControllerTest do
  use YouWeb.ConnCase, async: false

  alias You.AccountsFixtures

  setup do
    {:ok, app, secret} =
      You.Admin.create_app(%{
        slug: "fp-http",
        name: "FP HTTP",
        callback_url: "https://fp.example.com/cb",
        first_party: true
      })

    user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
    %{app: app, secret: secret, user: user, password: AccountsFixtures.valid_user_password()}
  end

  test "valid first-party login returns a token bundle", ctx do
    conn =
      post(build_conn(), ~p"/api/auth/login", %{
        "client_id" => ctx.app.slug,
        "client_secret" => ctx.secret,
        "email" => ctx.user.email,
        "password" => ctx.password,
        "scope" => "email roles"
      })

    assert %{"access_token" => jwt, "token_type" => "Bearer", "refresh_token" => rt, "user" => u} =
             json_response(conn, 200)

    assert is_binary(jwt)
    assert is_binary(rt)
    assert u["email"] == ctx.user.email
  end

  test "client auth via HTTP Basic also works", ctx do
    basic = "Basic " <> Base.encode64("#{ctx.app.slug}:#{ctx.secret}")

    conn =
      build_conn()
      |> put_req_header("authorization", basic)
      |> post(~p"/api/auth/login", %{
        "email" => ctx.user.email,
        "password" => ctx.password
      })

    assert %{"access_token" => _} = json_response(conn, 200)
  end

  test "wrong password is 401 invalid_credentials", ctx do
    conn =
      post(build_conn(), ~p"/api/auth/login", %{
        "client_id" => ctx.app.slug,
        "client_secret" => ctx.secret,
        "email" => ctx.user.email,
        "password" => "nope"
      })

    assert %{"error" => "invalid_credentials"} = json_response(conn, 401)
  end

  test "a non-first-party client is 403", ctx do
    {:ok, tp, tp_secret} =
      You.Admin.create_app(%{slug: "tp-http", name: "TP", callback_url: "https://tp/cb"})

    conn =
      post(build_conn(), ~p"/api/auth/login", %{
        "client_id" => tp.slug,
        "client_secret" => tp_secret,
        "email" => ctx.user.email,
        "password" => ctx.password
      })

    assert %{"error" => "unauthorized_client"} = json_response(conn, 403)
  end

  describe "POST /api/auth/register" do
    test "valid first-party registration returns 201 with a token bundle", ctx do
      email = AccountsFixtures.unique_user_email()

      conn =
        post(build_conn(), ~p"/api/auth/register", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => email,
          "password" => ctx.password,
          "scope" => "email roles"
        })

      assert %{
               "access_token" => jwt,
               "token_type" => "Bearer",
               "refresh_token" => rt,
               "user" => u
             } = json_response(conn, 201)

      assert is_binary(jwt)
      assert is_binary(rt)
      assert u["email"] == email

      # Created user must be unconfirmed.
      user = You.Repo.get_by(You.Accounts.User, email: email)
      assert user, "user should be persisted"
      assert is_nil(user.confirmed_at)
    end

    test "duplicate email returns 409", ctx do
      email = AccountsFixtures.unique_user_email()

      # First registration.
      post(build_conn(), ~p"/api/auth/register", %{
        "client_id" => ctx.app.slug,
        "client_secret" => ctx.secret,
        "email" => email,
        "password" => ctx.password
      })

      # Second with same email.
      conn =
        post(build_conn(), ~p"/api/auth/register", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => email,
          "password" => ctx.password
        })

      assert %{"error" => "email_taken"} = json_response(conn, 409)
    end

    test "short password returns 422", ctx do
      conn =
        post(build_conn(), ~p"/api/auth/register", %{
          "client_id" => ctx.app.slug,
          "client_secret" => ctx.secret,
          "email" => AccountsFixtures.unique_user_email(),
          "password" => "short"
        })

      assert %{"error" => "invalid_registration"} = json_response(conn, 422)
    end

    test "a non-first-party client is 403", ctx do
      {:ok, tp, tp_secret} =
        You.Admin.create_app(%{slug: "tp-reg-http", name: "TP", callback_url: "https://tp/cb"})

      conn =
        post(build_conn(), ~p"/api/auth/register", %{
          "client_id" => tp.slug,
          "client_secret" => tp_secret,
          "email" => AccountsFixtures.unique_user_email(),
          "password" => ctx.password
        })

      assert %{"error" => "unauthorized_client"} = json_response(conn, 403)
    end
  end
end
