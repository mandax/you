defmodule You.RolesTest do
  use You.DataCase, async: false

  alias You.Roles
  alias You.IAM.Claims

  defp app_fixture(attrs \\ %{}) do
    {:ok, app, _secret} =
      You.Admin.create_app(
        Map.merge(
          %{
            "name" => "Role App",
            "slug" => "role-app-#{System.unique_integer([:positive])}",
            "callback_url" => "https://app.example.com/cb"
          },
          attrs
        )
      )

    app
  end

  test "set_role assigns and changes a role; unassigned users default to user" do
    app = app_fixture()
    user = You.AccountsFixtures.user_fixture()

    assert Roles.role_for(app.slug, user.id) == "user"

    {:ok, _} = Roles.set_role(app, user, "admin")
    assert Roles.role_for(app.slug, user.id) == "admin"

    {:ok, _} = Roles.set_role(app, user, "user")
    assert Roles.role_for(app.slug, user.id) == "user"
  end

  test "set_role rejects roles outside the app's allowed_roles" do
    app = app_fixture(%{"allowed_roles" => ["user", "editor"]})
    user = You.AccountsFixtures.user_fixture()

    assert {:error, :invalid_role} = Roles.set_role(app, user, "admin")
    {:ok, _} = Roles.set_role(app, user, "editor")
    assert Roles.role_for(app.slug, user.id) == "editor"
  end

  test "remove_role resets to the implicit user role" do
    app = app_fixture()
    user = You.AccountsFixtures.user_fixture()

    {:ok, _} = Roles.set_role(app, user, "admin")
    assert Roles.remove_role(app, user) == 1
    assert Roles.role_for(app.slug, user.id) == "user"
  end

  test "list_for_app includes every user exactly once" do
    app = app_fixture()
    admin = You.AccountsFixtures.user_fixture()
    plain = You.AccountsFixtures.user_fixture()

    {:ok, _} = Roles.set_role(app, admin, "admin")

    members = Roles.list_for_app(app)
    roles = Map.new(members, fn {u, role} -> {u.id, role} end)

    assert roles[admin.id] == "admin"
    assert roles[plain.id] == "user"
    assert length(members) == length(Enum.uniq_by(members, fn {u, _} -> u.id end))
  end

  test "roles scope carries the per-app role; without an app it uses the admin flag" do
    app = app_fixture()
    user = You.AccountsFixtures.user_fixture()
    {:ok, _} = Roles.set_role(app, user, "admin")

    assert Claims.build_scoped_claims(user, ["roles"], app.slug)[:role] == "admin"
    assert Claims.build_scoped_claims(user, ["roles"])[:role] == "user"
    assert Claims.build_scoped_claims(user, ["roles"], "unknown-app")[:role] == "user"
  end

  test "auth code carries the app through consume into claims" do
    app = app_fixture()
    user = You.AccountsFixtures.user_fixture()
    {:ok, _} = Roles.set_role(app, user, "admin")

    {:ok, code} = You.Accounts.generate_auth_code(user, ["roles"], nil, app.slug)

    assert {:ok, consumed, ["roles"], slug} =
             You.Accounts.consume_auth_code(code, nil, client_authenticated: true)

    assert consumed.id == user.id
    assert slug == app.slug

    assert Claims.build_scoped_claims(consumed, ["roles"], slug)[:role] == "admin"
  end

  test "refresh tokens keep the app binding across rotation" do
    app = app_fixture()
    user = You.AccountsFixtures.user_fixture()

    token = You.Accounts.create_refresh_token(user, ["roles"], app.slug)
    assert {:ok, _, ["roles"], _new_token, slug} = You.Accounts.rotate_refresh_token(token)
    assert slug == app.slug
  end
end
