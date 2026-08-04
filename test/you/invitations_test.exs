defmodule You.InvitationsTest do
  @moduledoc """
  Before invitations, onboarding a named person meant asking them to register
  or pushing them in over SCIM from an upstream directory. Neither is
  something an operator can do for one person.
  """
  use You.DataCase, async: false

  alias You.Invitations
  alias You.Roles

  import You.AccountsFixtures

  setup do
    {:ok, app, _secret} =
      You.Admin.create_app(%{
        slug: "billing",
        name: "Meridian Billing",
        callback_url: "https://billing.example.com/cb",
        allowed_roles: ["user", "admin"]
      })

    %{app: app}
  end

  defp invite!(app, attrs \\ %{}) do
    attrs = Map.merge(%{email: unique_user_email(), app_id: app.id, role: "admin"}, attrs)
    {:ok, invitation, token} = Invitations.create(attrs)
    {invitation, token}
  end

  describe "creating" do
    test "stores only the hash of the token", %{app: app} do
      {invitation, token} = invite!(app)

      refute invitation.token == token
      assert invitation.token == :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
    end

    test "normalises the email", %{app: app} do
      {invitation, _token} = invite!(app, %{email: "  Person@Example.COM "})

      assert invitation.email == "person@example.com"
    end

    test "refuses a role the app does not allow", %{app: app} do
      assert {:error, :invalid_role} =
               Invitations.create(%{email: "a@b.c", app_id: app.id, role: "owner"})
    end

    test "refuses a role with no app to hold it" do
      assert {:error, :role_without_app} = Invitations.create(%{email: "a@b.c", role: "admin"})
    end

    test "refuses a malformed email", %{app: app} do
      assert {:error, changeset} = Invitations.create(%{email: "not-an-email", app_id: app.id})
      assert %{email: [_ | _]} = errors_on(changeset)
    end
  end

  describe "looking up" do
    test "finds a pending invitation by its token", %{app: app} do
      {invitation, token} = invite!(app)

      assert %{id: id} = Invitations.get_by_token(token)
      assert id == invitation.id
    end

    test "a garbage token is nil, not a crash" do
      assert Invitations.get_by_token("not-base64!!") == nil
      assert Invitations.get_by_token(nil) == nil
    end

    test "an expired invitation is not found", %{app: app} do
      {invitation, token} = invite!(app)
      backdate!(invitation, days: Invitations.validity_in_days() + 1)

      assert Invitations.get_by_token(token) == nil
    end

    test "an accepted invitation is not found again", %{app: app} do
      {invitation, token} = invite!(app)
      {:ok, user} = Invitations.resolve_user(invitation)
      {:ok, _user} = Invitations.accept(invitation, user)

      assert Invitations.get_by_token(token) == nil
    end
  end

  describe "accepting" do
    test "grants the role it promised", %{app: app} do
      {invitation, _token} = invite!(app, %{role: "admin"})
      {:ok, user} = Invitations.resolve_user(invitation)

      assert {:ok, ^user} = Invitations.accept(invitation, user)
      assert Roles.role_for(app.slug, user.id) == "admin"
    end

    test "creates a confirmed account when there is none", %{app: app} do
      {invitation, _token} = invite!(app, %{email: "newcomer@example.com"})

      assert {:ok, user} = Invitations.resolve_user(invitation)
      assert user.email == "newcomer@example.com"
      assert user.confirmed_at
    end

    test "uses the existing account when there is one", %{app: app} do
      existing = user_fixture()
      {invitation, _token} = invite!(app, %{email: existing.email})

      assert {:ok, user} = Invitations.resolve_user(invitation)
      assert user.id == existing.id
    end

    test "is single-use", %{app: app} do
      {invitation, _token} = invite!(app)
      {:ok, user} = Invitations.resolve_user(invitation)

      assert {:ok, _user} = Invitations.accept(invitation, user)
      assert {:error, :already_accepted} = Invitations.accept(invitation, user)
    end

    test "an invitation with no app grants no role but still resolves a user" do
      {:ok, invitation, _token} = Invitations.create(%{email: "solo@example.com"})

      assert {:ok, user} = Invitations.resolve_user(invitation)
      assert {:ok, ^user} = Invitations.accept(invitation, user)
    end
  end

  describe "listing and revoking" do
    test "lists pending invitations only", %{app: app} do
      {pending, _token} = invite!(app)
      {accepted, _token} = invite!(app)
      {:ok, user} = Invitations.resolve_user(accepted)
      {:ok, _user} = Invitations.accept(accepted, user)

      ids = Invitations.list_pending() |> Enum.map(& &1.id)

      assert pending.id in ids
      refute accepted.id in ids
    end

    test "revoking withdraws it", %{app: app} do
      {invitation, token} = invite!(app)

      assert Invitations.revoke(invitation.id) == 1
      assert Invitations.get_by_token(token) == nil
    end

    test "revoking an accepted invitation does nothing", %{app: app} do
      {invitation, _token} = invite!(app)
      {:ok, user} = Invitations.resolve_user(invitation)
      {:ok, _user} = Invitations.accept(invitation, user)

      assert Invitations.revoke(invitation.id) == 0
    end
  end

  describe "the email" do
    test "names the app and the role, and carries the link", %{app: app} do
      {:ok, _invitation} =
        Invitations.invite(
          %{email: "invitee@example.com", app_id: app.id, role: "admin"},
          &"https://you.example.com/invitations/#{&1}"
        )

      assert_receive {:email, email}
      assert email.to == [{"", "invitee@example.com"}]
      assert email.text_body =~ "Meridian Billing"
      assert email.text_body =~ "admin"
      assert email.text_body =~ "https://you.example.com/invitations/"
    end

    test "the link in it opens the invitation", %{app: app} do
      {:ok, _invitation} =
        Invitations.invite(
          %{email: "invitee@example.com", app_id: app.id, role: "user"},
          &"https://you.example.com/invitations/#{&1}"
        )

      assert_receive {:email, email}
      [_, token] = Regex.run(~r{/invitations/([^\s]+)}, email.text_body)

      assert %{email: "invitee@example.com"} = Invitations.get_by_token(token)
    end
  end

  defp backdate!(invitation, days: days) do
    then = DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)

    Repo.update_all(
      from(i in You.Invitations.Invitation, where: i.id == ^invitation.id),
      set: [inserted_at: then]
    )
  end
end
