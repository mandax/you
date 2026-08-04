defmodule YouWeb.InvitationControllerTest do
  @moduledoc """
  Accepting an invitation: what the invitee sees, what it grants, and what it
  refuses to be — a login that skips an enrolled second factor.
  """
  use YouWeb.ConnCase, async: false

  alias You.Accounts
  alias You.Invitations
  alias You.Roles

  import You.AccountsFixtures

  setup do
    {:ok, app, _secret} =
      You.Admin.create_app(%{
        slug: "billing",
        name: "Meridian Billing",
        callback_url: "https://billing.example.com/cb"
      })

    %{app: app}
  end

  defp invite!(app, attrs \\ %{}) do
    attrs = Map.merge(%{email: unique_user_email(), app_id: app.id, role: "admin"}, attrs)
    {:ok, _invitation, token} = Invitations.create(attrs)
    token
  end

  describe "GET /invitations/:token" do
    test "shows what is being accepted", %{conn: conn, app: app} do
      token = invite!(app, %{email: "invitee@example.com"})

      html = conn |> get(~p"/invitations/#{token}") |> html_response(200)

      assert html =~ "Meridian Billing"
      assert html =~ "invitee@example.com"
      assert html =~ "admin"
    end

    test "does not spend the invitation, so a mail client preview is harmless",
         %{conn: conn, app: app} do
      token = invite!(app)

      get(conn, ~p"/invitations/#{token}")

      assert Invitations.get_by_token(token)
    end

    test "an unknown token is turned away", %{conn: conn} do
      conn = get(conn, ~p"/invitations/nonsense")

      assert redirected_to(conn) == ~p"/users/log-in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid, expired, or already used"
    end
  end

  describe "POST /invitations/:token" do
    test "creates the account, grants the role, and signs the invitee in",
         %{conn: conn, app: app} do
      token = invite!(app, %{email: "newcomer@example.com", role: "admin"})

      conn = post(conn, ~p"/invitations/#{token}")

      assert get_session(conn, :user_token)
      user = Accounts.get_user_by_email("newcomer@example.com")
      assert user.confirmed_at
      assert Roles.role_for(app.slug, user.id) == "admin"
    end

    test "grants the role on an account that already exists", %{conn: conn, app: app} do
      existing = user_fixture()
      token = invite!(app, %{email: existing.email, role: "admin"})

      post(conn, ~p"/invitations/#{token}")

      assert Roles.role_for(app.slug, existing.id) == "admin"
    end

    test "is single-use", %{conn: conn, app: app} do
      token = invite!(app)

      post(conn, ~p"/invitations/#{token}")
      conn = post(build_conn(), ~p"/invitations/#{token}")

      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "does not sign in past an enrolled second factor", %{conn: conn, app: app} do
      user = user_fixture()
      {:ok, setup} = Accounts.generate_totp_setup(user)

      {:ok, _result} =
        Accounts.enable_totp(setup.user, NimbleTOTP.verification_code(setup.secret))

      token = invite!(app, %{email: user.email, role: "admin"})

      conn = post(conn, ~p"/invitations/#{token}")

      assert redirected_to(conn) == ~p"/users/log-in/totp"
      refute get_session(conn, :user_token)

      # The role still lands: the invitation was accepted, the session was not
      # handed over without the second factor.
      assert Roles.role_for(app.slug, user.id) == "admin"
    end
  end
end
