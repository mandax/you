defmodule You.Repo do
  use Ecto.Repo,
    otp_app: :you,
    adapter: Ecto.Adapters.SQLite3
end
