defmodule You.EmailTemplates.EmailTemplate do
  @moduledoc """
  A customised transactional email. See `You.EmailTemplates`.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  schema "email_templates" do
    field :key, :string
    field :subject, :string
    field :body, :string

    timestamps()
  end

  @doc false
  def changeset(template, attrs, required_variables \\ []) do
    template
    |> cast(attrs, [:key, :subject, :body])
    |> update_change(:subject, &String.trim/1)
    |> validate_required([:key, :subject, :body])
    |> validate_length(:subject, max: 200)
    |> validate_length(:body, max: 10_000)
    |> validate_variables(required_variables)
    |> unique_constraint(:key)
  end

  # A magic-link email with no {{url}} in it is not a style choice, it is a
  # login nobody can complete. The check is on the body and the subject
  # together, since either may carry it.
  defp validate_variables(changeset, required_variables) do
    subject = get_field(changeset, :subject) || ""
    body = get_field(changeset, :body) || ""
    text = subject <> body

    missing = Enum.reject(required_variables, &String.contains?(text, "{{#{&1}}}"))

    if missing == [] do
      changeset
    else
      add_error(changeset, :body, "must include #{Enum.map_join(missing, ", ", &"{{#{&1}}}")}")
    end
  end
end
