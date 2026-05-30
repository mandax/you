defmodule You.Accounts.CookieSync do
  @moduledoc """
  Reads `erlang_cookie` from settings after boot and applies it to the
  Erlang VM. This lets operators manage the distribution cookie through
  the admin settings page instead of only via env vars.

  The cookie from settings overrides whatever was set via `RELEASE_COOKIE`
  at container start. Changing the cookie in settings takes effect
  immediately (no restart needed), but existing Erlang distribution
  connections established with the old cookie will break.

  Only applies when the node is part of a distributed system
  (Node.self != nonode@nohost). In development (mix phx.server),
  distribution is typically not active and this is a no-op.
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    apply_cookie()
    {:ok, %{}}
  end

  @doc """
  Reads `erlang_cookie` from settings and applies it to the local node.
  Safe to call multiple times — no-op if no cookie is configured or if
  the node isn't distributed.
  """
  def apply_cookie do
    node = Node.self()

    if node != :nonode@nohost do
      case You.Settings.get(:erlang_cookie) do
        cookie when is_binary(cookie) and cookie != "" ->
          Node.set_cookie(node, String.to_atom(cookie))

        _ ->
          :ok
      end
    end
  end
end
