defmodule You.GuestsTest do
  @moduledoc """
  Consumer apps want state before signup, and want it to survive the signup.
  The load-bearing property is that upgrading keeps the same user id: an app
  that has already written that id into its own rows must not have to merge
  two identities afterwards.
  """
  use You.DataCase, async: false

  alias You.Accounts
  alias You.Guests
  alias You.IAM.Claims
  alias You.Settings

  import You.AccountsFixtures

  setup do
    Settings.set(:feature_guest_login, true)
    :ok
  end

  describe "creating" do
    test "makes a confirmed, passwordless account" do
      assert {:ok, guest} = Guests.create()

      assert guest.is_guest
      assert guest.confirmed_at
      refute guest.hashed_password
      assert guest.email =~ "@#{Guests.email_domain()}"
    end

    test "each guest gets its own placeholder address" do
      {:ok, one} = Guests.create()
      {:ok, two} = Guests.create()

      refute one.email == two.email
    end

    test "is refused when the instance has not switched it on" do
      Settings.set(:feature_guest_login, false)

      assert {:error, :guests_disabled} = Guests.create()
    end
  end

  describe "the token" do
    test "says guest, so a consumer app can gate on it" do
      {:ok, guest} = Guests.create()

      assert %{guest: true} = Claims.build_scoped_claims(guest, ["email"])
    end

    test "a real account carries no guest claim at all, not guest: false" do
      user = user_fixture()

      refute Map.has_key?(Claims.build_scoped_claims(user, ["email"]), :guest)
    end

    test "an app cannot forge it" do
      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "forger",
          name: "Forger",
          callback_url: "https://forger.example.com/cb"
        })

      assert {:error, changeset} =
               You.Admin.update_app(app, %{"custom_claims" => %{"guest" => false}})

      assert %{custom_claims: [_ | _]} = errors_on(changeset)
    end
  end

  describe "upgrading" do
    test "keeps the same row, so the user id an app stored still points at them" do
      {:ok, guest} = Guests.create()

      assert {:ok, user} =
               Guests.upgrade(guest, %{
                 email: "person@example.com",
                 password: valid_user_password()
               })

      assert user.id == guest.id
      assert user.email == "person@example.com"
      refute user.is_guest
    end

    test "the account can then sign in with the password it was given" do
      {:ok, guest} = Guests.create()

      {:ok, _user} =
        Guests.upgrade(guest, %{email: "person@example.com", password: valid_user_password()})

      assert %{} =
               Accounts.get_user_by_email_and_password(
                 "person@example.com",
                 valid_user_password()
               )
    end

    test "keeps the roles the guest was given" do
      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "shop",
          name: "Shop",
          callback_url: "https://shop.example.com/cb"
        })

      {:ok, guest} = Guests.create()
      {:ok, _assignment} = You.Roles.set_role(app, guest, "admin")

      {:ok, user} =
        Guests.upgrade(guest, %{email: "person@example.com", password: valid_user_password()})

      assert You.Roles.role_for(app.slug, user.id) == "admin"
    end

    test "an account that is not a guest is refused" do
      assert {:error, :not_a_guest} =
               Guests.upgrade(user_fixture(), %{
                 email: "other@example.com",
                 password: valid_user_password()
               })
    end

    test "upgrading twice is refused" do
      {:ok, guest} = Guests.create()

      {:ok, user} =
        Guests.upgrade(guest, %{email: "person@example.com", password: valid_user_password()})

      assert {:error, :not_a_guest} =
               Guests.upgrade(user, %{email: "again@example.com", password: valid_user_password()})
    end

    test "an email already in use is refused, and the guest stays a guest" do
      existing = user_fixture()
      {:ok, guest} = Guests.create()

      assert {:error, changeset} =
               Guests.upgrade(guest, %{email: existing.email, password: valid_user_password()})

      assert %{email: [_ | _]} = errors_on(changeset)
      assert Repo.get(Accounts.User, guest.id).is_guest
    end

    test "a bad password is refused, and the email is not claimed" do
      {:ok, guest} = Guests.create()

      assert {:error, _changeset} =
               Guests.upgrade(guest, %{email: "person@example.com", password: "short"})

      reloaded = Repo.get(Accounts.User, guest.id)
      assert reloaded.is_guest
      refute reloaded.email == "person@example.com"
    end
  end

  describe "a guest is not a mailbox" do
    test "its placeholder address resolves to nobody" do
      {:ok, guest} = Guests.create()

      assert Accounts.get_user_by_email(guest.email) == nil
    end
  end

  describe "cleanup" do
    test "deletes guests nobody came back for" do
      {:ok, stale} = Guests.create()
      {:ok, fresh} = Guests.create()
      backdate!(stale, days: 31)

      assert Guests.delete_stale(30) == 1
      refute Repo.get(Accounts.User, stale.id)
      assert Repo.get(Accounts.User, fresh.id)
    end

    test "never touches an upgraded account, however old" do
      {:ok, guest} = Guests.create()

      {:ok, user} =
        Guests.upgrade(guest, %{email: "person@example.com", password: valid_user_password()})

      backdate!(user, days: 400)

      assert Guests.delete_stale(30) == 0
      assert Repo.get(Accounts.User, user.id)
    end

    test "never touches a real account" do
      user = user_fixture()
      backdate!(user, days: 400)

      assert Guests.delete_stale(30) == 0
      assert Repo.get(Accounts.User, user.id)
    end
  end

  defp backdate!(user, days: days) do
    then = DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)

    Repo.update_all(
      from(u in Accounts.User, where: u.id == ^user.id),
      set: [inserted_at: then]
    )
  end
end
