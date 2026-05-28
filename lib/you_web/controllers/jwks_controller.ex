defmodule YouWeb.JwksController do
  use YouWeb, :controller

  @doc """
  GET /.well-known/jwks.json

  Returns You's Ed25519 public key in JWK format for client-side
  JWT verification.
  """
  def show(conn, _params) do
    jwk_map = You.SDK.Verify.export_public_key()
    json(conn, %{keys: [jwk_map]})
  end
end
