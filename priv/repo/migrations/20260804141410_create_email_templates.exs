defmodule You.Repo.Migrations.CreateEmailTemplates do
  @moduledoc """
  Overrides for the transactional emails You sends.

  One row per template that has been customised; a template with no row uses
  the copy compiled into `You.EmailTemplates`. Storing only the overrides means
  an instance that never touches this keeps getting improvements to the default
  wording, and "reset to default" is a delete rather than a copy.
  """
  use Ecto.Migration

  def change do
    create table(:email_templates) do
      add :key, :string, null: false
      add :subject, :string
      add :body, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:email_templates, [:key])
  end
end
