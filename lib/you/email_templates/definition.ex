defmodule You.EmailTemplates.Definition do
  @moduledoc """
  One of the transactional emails You sends, as compiled in.

  A struct rather than a bare map because the set is fixed and known at
  compile time: `@enforce_keys` makes a template added without its `required`
  list a compile error instead of a `nil` that surfaces as an unvalidated
  email months later, and a mistyped field name fails where it is written
  rather than silently reading as absent.

  Distinct from `You.EmailTemplates.EmailTemplate`, which is the Ecto schema
  for an admin's *override* of one of these. A definition is code; an override
  is a row.

  ## Fields

    * `key` — the stable identifier the override table and the console form
      use. Never change one; it is the join between code and stored rows.
    * `label`, `description` — what the console calls it, and what it is for.
    * `variables` — every `{{name}}` the renderer will substitute.
    * `required` — the subset a template cannot do without, enforced by
      `You.EmailTemplates.EmailTemplate.changeset/3`. A magic link with no
      `{{url}}` is not a style choice, it is a login nobody can complete.
    * `subject`, `body` — the default copy, used until an override exists.
  """

  @enforce_keys [:key, :label, :description, :variables, :required, :subject, :body]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: String.t(),
          label: String.t(),
          description: String.t(),
          variables: [String.t()],
          required: [String.t()],
          subject: String.t(),
          body: String.t()
        }
end
