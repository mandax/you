defmodule You.OrganizationsTest do
  use You.DataCase, async: false

  alias You.Organizations
  alias You.Organizations.{Organization, Membership}
  alias You.AccountsFixtures

  describe "create_organization/1" do
    test "creates an organization with valid attrs" do
      assert {:ok, %Organization{} = org} =
               Organizations.create_organization(%{name: "Acme Corp", slug: "acme-corp"})

      assert org.name == "Acme Corp"
      assert org.slug == "acme-corp"
    end

    test "returns error when name is missing" do
      assert {:error, changeset} = Organizations.create_organization(%{slug: "acme-corp"})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "returns error when slug is missing" do
      assert {:error, changeset} = Organizations.create_organization(%{name: "Acme Corp"})
      assert "can't be blank" in errors_on(changeset).slug
    end

    test "enforces unique slug" do
      Organizations.create_organization(%{name: "Acme Corp", slug: "acme-corp"})

      assert {:error, changeset} =
               Organizations.create_organization(%{name: "Acme Corp 2", slug: "acme-corp"})

      assert errors_on(changeset).slug
    end
  end

  describe "get_organization/1" do
    test "returns the organization by id" do
      {:ok, org} = Organizations.create_organization(%{name: "Acme Corp", slug: "acme-corp"})
      assert %Organization{name: "Acme Corp"} = Organizations.get_organization(org.id)
    end
  end

  describe "list_organizations/0" do
    test "returns all organizations" do
      Organizations.create_organization(%{name: "Acme Corp", slug: "acme-corp"})
      Organizations.create_organization(%{name: "Beta Inc", slug: "beta-inc"})

      orgs = Organizations.list_organizations()
      assert length(orgs) == 2
      slugs = Enum.map(orgs, & &1.slug) |> Enum.sort()
      assert slugs == ["acme-corp", "beta-inc"]
    end

    test "returns empty list when no organizations exist" do
      assert Organizations.list_organizations() == []
    end
  end

  describe "add_member/3" do
    setup do
      {:ok, org} = Organizations.create_organization(%{name: "Acme Corp", slug: "acme-corp"})
      user = AccountsFixtures.user_fixture()
      %{org: org, user: user}
    end

    test "adds a user with default role member", %{org: org, user: user} do
      assert {:ok, %Membership{role: "member"}} = Organizations.add_member(org, user)
    end

    test "adds a user with a specific role", %{org: org, user: user} do
      assert {:ok, %Membership{role: "admin"}} = Organizations.add_member(org, user, "admin")
    end

    test "rejects a duplicate membership", %{org: org, user: user} do
      {:ok, _} = Organizations.add_member(org, user)
      assert {:error, changeset} = Organizations.add_member(org, user)
      assert errors_on(changeset).organization_id
    end

    test "rejects an invalid role", %{org: org, user: user} do
      assert {:error, changeset} = Organizations.add_member(org, user, "superadmin")
      assert "is invalid" in errors_on(changeset).role
    end
  end

  describe "remove_member/2" do
    setup do
      {:ok, org} = Organizations.create_organization(%{name: "Acme Corp", slug: "acme-corp"})
      user = AccountsFixtures.user_fixture()
      %{org: org, user: user}
    end

    test "removes the user from the organization", %{org: org, user: user} do
      {:ok, _membership} = Organizations.add_member(org, user)
      assert {:ok, _} = Organizations.remove_member(org, user)
      assert Organizations.list_members(org) == []
    end

    test "returns error when user is not a member", %{org: org, user: user} do
      assert {:error, :not_found} = Organizations.remove_member(org, user)
    end
  end

  describe "list_members/1" do
    setup do
      {:ok, org} = Organizations.create_organization(%{name: "Acme Corp", slug: "acme-corp"})
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()
      {:ok, _} = Organizations.add_member(org, user1, "owner")
      {:ok, _} = Organizations.add_member(org, user2, "member")
      %{org: org, user1: user1, user2: user2}
    end

    test "returns all members with roles", %{org: org, user1: user1, user2: user2} do
      members = Organizations.list_members(org)
      assert length(members) == 2

      roles = Enum.map(members, fn {_user, role} -> role end) |> Enum.sort()
      assert roles == ["member", "owner"]

      user_ids = Enum.map(members, fn {user, _role} -> user.id end) |> Enum.sort()
      assert user_ids == Enum.sort([user1.id, user2.id])
    end

    test "returns empty list when no members" do
      {:ok, empty_org} =
        Organizations.create_organization(%{name: "Empty Inc", slug: "empty-inc"})

      assert Organizations.list_members(empty_org) == []
    end
  end

  describe "update_member_role/3" do
    setup do
      {:ok, org} = Organizations.create_organization(%{name: "Acme Corp", slug: "acme-corp"})
      user = AccountsFixtures.user_fixture()
      {:ok, _} = Organizations.add_member(org, user, "member")
      %{org: org, user: user}
    end

    test "updates the member's role", %{org: org, user: user} do
      assert {:ok, %Membership{role: "admin"}} =
               Organizations.update_member_role(org, user, "admin")

      assert [{^user, "admin"}] = Organizations.list_members(org)
    end

    test "returns error when user is not a member", %{org: org} do
      user = AccountsFixtures.user_fixture()
      assert {:error, :not_found} = Organizations.update_member_role(org, user, "admin")
    end

    test "rejects invalid role", %{org: org, user: user} do
      assert {:error, changeset} = Organizations.update_member_role(org, user, "superadmin")
      assert "is invalid" in errors_on(changeset).role
    end
  end
end
