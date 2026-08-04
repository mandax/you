defmodule You.CustomClaimsTest do
  @moduledoc """
  An app declares static claims once and reads them out of every token issued
  for it, instead of paying a round-trip to fetch its own tenant id or plan.
  Additive only: it can never rewrite the claims You issues.
  """
  use You.DataCase, async: false

  alias You.Admin
  alias You.Admin.App
  alias You.IAM.Claims

  import You.AccountsFixtures

  defp app_fixture(attrs) do
    n = System.unique_integer([:positive])

    {:ok, app, _secret} =
      Admin.create_app(
        Map.merge(
          %{slug: "app-#{n}", name: "App", callback_url: "https://app-#{n}.example.com/cb"},
          attrs
        )
      )

    app
  end

  describe "issuing" do
    test "declared claims reach the token" do
      app = app_fixture(%{custom_claims: %{"tenant_id" => "acme", "plan" => "pro"}})
      user = user_fixture()

      claims = Claims.build_scoped_claims(user, ["email"], app.slug)

      assert claims["tenant_id"] == "acme"
      assert claims["plan"] == "pro"
      assert claims.sub == user.id
    end

    test "an app that declares none is unchanged" do
      app = app_fixture(%{})
      user = user_fixture()

      assert Claims.build_scoped_claims(user, ["email"], app.slug) == %{
               sub: user.id,
               app: "you",
               email: user.email
             }
    end

    test "a first-party login with no app carries none" do
      user = user_fixture()

      assert Claims.build_scoped_claims(user, ["email"]) == %{
               sub: user.id,
               app: "you",
               email: user.email
             }
    end

    test "an unknown slug is an ordinary outcome, not a crash" do
      user = user_fixture()

      assert %{sub: _} = Claims.build_scoped_claims(user, ["email"], "no-such-app")
    end

    test "lists and numbers survive the round trip" do
      app =
        app_fixture(%{custom_claims: %{"seats" => 25, "features" => ["a", "b"], "beta" => true}})

      user = user_fixture()

      claims = Claims.build_scoped_claims(user, ["email"], app.slug)

      assert claims["seats"] == 25
      assert claims["features"] == ["a", "b"]
      assert claims["beta"] == true
    end
  end

  describe "they can only add" do
    test "a row carrying a reserved claim cannot shadow the one You issues" do
      app = app_fixture(%{})

      # Straight past the changeset, as a row written before a name joined the
      # reserved set would be.
      Repo.update_all(
        from(a in App, where: a.id == ^app.id),
        set: [custom_claims: %{"sub" => "9999", "role" => "admin", "tenant_id" => "acme"}]
      )

      user = user_fixture()
      claims = Claims.build_scoped_claims(user, ["roles"], app.slug)

      assert claims.sub == user.id
      assert claims.role == "user"
      assert claims["tenant_id"] == "acme"
    end

    test "and the changeset refuses it in the first place" do
      app = app_fixture(%{})

      assert {:error, changeset} =
               Admin.update_app(app, %{"custom_claims" => %{"sub" => "9999"}})

      assert %{custom_claims: [message]} = errors_on(changeset)
      assert message =~ "sub"
    end

    test "every reserved name is refused" do
      app = app_fixture(%{})

      for name <- App.reserved_claims() do
        assert {:error, _changeset} =
                 Admin.update_app(app, %{"custom_claims" => %{name => "x"}}),
               "#{name} was accepted as a custom claim"
      end
    end
  end

  describe "bounds" do
    test "a nested object is refused: a token is for facts, not shapes" do
      app = app_fixture(%{})

      assert {:error, changeset} =
               Admin.update_app(app, %{"custom_claims" => %{"org" => %{"id" => 1}}})

      assert %{custom_claims: [_ | _]} = errors_on(changeset)
    end

    test "a claim name with spaces is refused" do
      app = app_fixture(%{})

      assert {:error, changeset} =
               Admin.update_app(app, %{"custom_claims" => %{"tenant id" => "acme"}})

      assert %{custom_claims: [_ | _]} = errors_on(changeset)
    end

    test "an oversized payload is refused, because a JWT rides in a header" do
      app = app_fixture(%{})
      big = String.duplicate("x", App.max_custom_claims_bytes() + 1)

      assert {:error, changeset} =
               Admin.update_app(app, %{"custom_claims" => %{"blob" => big}})

      assert %{custom_claims: [_ | _]} = errors_on(changeset)
    end

    test "too many claims are refused" do
      app = app_fixture(%{})
      many = Map.new(1..40, &{"claim_#{&1}", "v"})

      assert {:error, changeset} = Admin.update_app(app, %{"custom_claims" => many})
      assert %{custom_claims: [_ | _]} = errors_on(changeset)
    end

    test "clearing back to an empty object is allowed" do
      app = app_fixture(%{custom_claims: %{"tenant_id" => "acme"}})

      assert {:ok, app} = Admin.update_app(app, %{"custom_claims" => %{}})
      assert App.custom_claims(app) == %{}
    end
  end

  describe "signed tokens" do
    test "a verified JWT carries the app's claims" do
      app = app_fixture(%{custom_claims: %{"tenant_id" => "acme"}})
      user = user_fixture()

      {:ok, jwt} =
        You.JWT.sign(Claims.build_scoped_claims(user, ["email"], app.slug), 3600)

      assert {:ok, payload} = You.JWT.verify(jwt)
      assert payload["tenant_id"] == "acme"
      assert payload["sub"] == user.id
    end
  end
end
