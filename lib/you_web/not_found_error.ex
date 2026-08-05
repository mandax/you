defmodule YouWeb.NotFoundError do
  @moduledoc """
  Raised for a path that is well-formed but names nothing — a console
  section that does not exist, for instance. Distinct from
  `Ecto.NoResultsError` (a lookup that missed a real row): nothing was
  queried, so nothing is missing, an address just was never valid.

  Implements `Plug.Exception` with `plug_status: 404` so it renders through
  the ordinary error page rather than a 500.
  """
  defexception message: "not found", plug_status: 404
end
