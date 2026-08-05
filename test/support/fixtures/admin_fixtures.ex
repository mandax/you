defmodule You.AdminFixtures do
  @moduledoc """
  Test helpers for creating entities via the `You.Admin` context.
  """

  alias You.Admin.App

  @doc """
  Inserts an app whose slug bypasses `App.changeset/2`, simulating a row
  written before the slug format validation existed.
  """
  def insert_legacy_app!(slug) do
    %App{}
    |> Ecto.Changeset.change(%{
      slug: slug,
      name: "Legacy",
      callback_url: "https://legacy-#{System.unique_integer([:positive])}.example.com/cb",
      allowed_roles: ["user", "admin"],
      default_role: "user"
    })
    |> You.Repo.insert!()
  end
end
