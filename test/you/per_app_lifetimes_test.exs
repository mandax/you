defmodule You.PerAppLifetimesTest do
  @moduledoc """
  A token lifetime is an app's decision, not an instance's: an internal admin
  tool and a public mobile client should not share one expiry. `nil` on the
  column keeps following the instance setting, the same convention
  `enabled_methods` and `enabled_providers` already use.
  """
  use You.DataCase, async: false

  alias You.Accounts
  alias You.Admin
  alias You.Admin.App
  alias You.Settings

  import You.AccountsFixtures

  defp app_fixture(attrs) do
    {:ok, app, _secret} =
      Admin.create_app(
        Map.merge(
          %{
            slug: "app-#{System.unique_integer([:positive])}",
            name: "App",
            callback_url: "https://app-#{System.unique_integer([:positive])}.example.com/cb"
          },
          attrs
        )
      )

    app
  end

  describe "resolution" do
    test "an app with no override follows the instance" do
      Settings.set(:jwt_expiry_hours, 4)
      app = app_fixture(%{})

      assert App.resolved_jwt_expiry_hours(app) == 4
      assert Admin.jwt_expiry_seconds(app) == 4 * 3600
    end

    test "an override wins over the instance" do
      Settings.set(:jwt_expiry_hours, 4)
      app = app_fixture(%{jwt_expiry_hours: 12})

      assert Admin.jwt_expiry_seconds(app) == 12 * 3600
    end

    test "an override keeps its own value when the instance default moves" do
      app = app_fixture(%{jwt_expiry_hours: 12})
      Settings.set(:jwt_expiry_hours, 2)

      assert Admin.jwt_expiry_seconds(app.slug) == 12 * 3600
    end

    test "an app that never overrode follows the instance when it moves" do
      app = app_fixture(%{})
      Settings.set(:jwt_expiry_hours, 2)

      assert Admin.jwt_expiry_seconds(app.slug) == 2 * 3600
    end

    test "an unknown slug falls back rather than raising" do
      Settings.set(:jwt_expiry_hours, 3)

      assert Admin.jwt_expiry_seconds("no-such-app") == 3 * 3600
      assert Admin.jwt_expiry_seconds(nil) == 3 * 3600
    end
  end

  describe "bounds" do
    test "a lifetime must be positive" do
      assert {:error, changeset} =
               Admin.create_app(%{
                 slug: "zero",
                 name: "Zero",
                 callback_url: "https://zero.example.com/cb",
                 jwt_expiry_hours: 0
               })

      assert %{jwt_expiry_hours: [_ | _]} = errors_on(changeset)
    end

    test "a year of JWT is refused" do
      app = app_fixture(%{})

      assert {:error, changeset} = Admin.update_app(app, %{"jwt_expiry_hours" => 8760})
      assert %{jwt_expiry_hours: [_ | _]} = errors_on(changeset)
    end

    test "an auth code cannot be stretched past an hour" do
      app = app_fixture(%{})

      assert {:error, changeset} = Admin.update_app(app, %{"code_expiry_minutes" => 1440})
      assert %{code_expiry_minutes: [_ | _]} = errors_on(changeset)
    end

    test "clearing an override back to nil is allowed" do
      app = app_fixture(%{jwt_expiry_hours: 12})

      assert {:ok, app} = Admin.update_app(app, %{"jwt_expiry_hours" => nil})
      assert app.jwt_expiry_hours == nil
    end
  end

  describe "issued tokens carry the app's lifetime" do
    test "the OIDC token response reports the app's expires_in" do
      Settings.set(:jwt_expiry_hours, 1)
      app = app_fixture(%{jwt_expiry_hours: 8})
      user = user_fixture()

      response = You.OIDC.issue_token_response(user, ["email"], app.slug)

      assert response.expires_in == 8 * 3600
    end

    test "and the instance default when the app has no override" do
      Settings.set(:jwt_expiry_hours, 1)
      app = app_fixture(%{})
      user = user_fixture()

      response = You.OIDC.issue_token_response(user, ["email"], app.slug)

      assert response.expires_in == 3600
    end
  end

  describe "authorization codes" do
    test "a code outlives the instance default when its app says so" do
      Settings.set(:code_expiry_minutes, 5)
      app = app_fixture(%{code_expiry_minutes: 30})
      user = user_fixture()

      {:ok, code} = Accounts.generate_auth_code(user, ["email"], nil, app.slug)
      age_code!(code, minutes: 10)

      assert {:ok, redeemed, _scopes, slug} =
               Accounts.consume_auth_code(code, nil, client_authenticated: true)

      assert redeemed.id == user.id
      assert slug == app.slug
    end

    test "a code from an app with no override still expires on the instance clock" do
      Settings.set(:code_expiry_minutes, 5)
      app = app_fixture(%{})
      user = user_fixture()

      {:ok, code} = Accounts.generate_auth_code(user, ["email"], nil, app.slug)
      age_code!(code, minutes: 10)

      assert {:error, :not_found} =
               Accounts.consume_auth_code(code, nil, client_authenticated: true)
    end

    # The lookup is bounded by the longest expiry any app can pin, so a code
    # past its own app's shorter expiry is still found — and has to be
    # destroyed on the way to refusing it, not left for a second attempt.
    test "a code refused on its app's clock is spent, not left behind" do
      Settings.set(:code_expiry_minutes, 5)
      app_fixture(%{code_expiry_minutes: 60})
      app = app_fixture(%{})
      user = user_fixture()

      {:ok, code} = Accounts.generate_auth_code(user, ["email"], nil, app.slug)
      age_code!(code, minutes: 10)

      assert {:error, :not_found} =
               Accounts.consume_auth_code(code, nil, client_authenticated: true)

      assert Repo.aggregate(
               from(t in You.Accounts.UserToken, where: t.context == "oauth_code"),
               :count
             ) == 0
    end

    # Backdates the stored code so it is older than an expiry without waiting.
    defp age_code!(code, minutes: minutes) do
      hash = :crypto.hash(:sha256, Base.url_decode64!(code, padding: false))
      then = DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

      {1, _} =
        Repo.update_all(
          from(t in You.Accounts.UserToken, where: t.token == ^hash),
          set: [inserted_at: then]
        )
    end
  end

  describe "JTI retention" do
    test "is measured against the longest lifetime any app can produce" do
      Settings.set(:jwt_expiry_hours, 1)
      app_fixture(%{jwt_expiry_hours: 48})

      assert Admin.max_jwt_expiry_hours() == 48
    end

    test "falls back to the instance when no app overrides" do
      Settings.set(:jwt_expiry_hours, 7)
      app_fixture(%{})

      assert Admin.max_jwt_expiry_hours() == 7
    end

    test "never drops below the instance setting" do
      Settings.set(:jwt_expiry_hours, 24)
      app_fixture(%{jwt_expiry_hours: 2})

      assert Admin.max_jwt_expiry_hours() == 24
    end

    test "a revocation survives as long as the longest-lived token carrying it" do
      Settings.set(:jwt_expiry_hours, 1)
      app_fixture(%{jwt_expiry_hours: 48})

      user = user_fixture()
      {:ok, jwt} = You.JWT.sign(%{sub: to_string(user.id)}, 48 * 3600)
      :ok = You.JWT.revoke(jwt)

      backdate_revocations!(hours: 5)
      Accounts.cleanup_revoked_jtis()

      assert {:error, :revoked} = You.JWT.verify(jwt)
    end

    defp backdate_revocations!(hours: hours) do
      then = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
      Repo.update_all(You.Accounts.RevokedJti, set: [inserted_at: then])
    end
  end
end
