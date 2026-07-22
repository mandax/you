defmodule YouWeb.WebAuthnController do
  use YouWeb, :controller

  alias You.Accounts
  alias You.Accounts.Passkey

  @doc """
  Returns PublicKeyCredentialCreationOptions for the registration ceremony.

  The challenge is persisted in the session so `finish_registration/2` can
  verify the attestation response.
  """
  def start_registration(conn, _params) do
    user = conn.assigns.current_scope.user
    existing_passkeys = Accounts.list_user_passkeys(user)

    challenge =
      Wax.new_registration_challenge(
        attestation: "none",
        user_verification: "preferred"
      )

    options = %{
      publicKey: %{
        rp: %{name: "You", id: challenge.rp_id},
        user: %{
          id: Base.url_encode64(user.id, padding: false),
          name: user.email,
          displayName: user.email
        },
        challenge: Base.url_encode64(challenge.bytes, padding: false),
        pubKeyCredParams: [
          %{type: "public-key", alg: -7},
          %{type: "public-key", alg: -257}
        ],
        timeout: 120_000,
        attestation: "none",
        excludeCredentials:
          Enum.map(existing_passkeys, fn pk ->
            %{id: Base.url_encode64(pk.credential_id, padding: false), type: "public-key"}
          end)
      }
    }

    conn
    |> put_session(:webauthn_challenge, challenge)
    |> json(options)
  end

  @doc """
  Verifies the attestation response from the browser and stores the new credential.
  """
  def finish_registration(conn, params) do
    user = conn.assigns.current_scope.user

    with challenge when not is_nil(challenge) <- get_session(conn, :webauthn_challenge),
         raw_id <- decode_param(params["rawId"] || params["id"]),
         {:ok, raw_id} <- raw_id,
         att_obj <- decode_param(get_in(params, ["response", "attestationObject"])),
         {:ok, att_obj} <- att_obj,
         cdj <- decode_param(get_in(params, ["response", "clientDataJSON"])),
         {:ok, cdj} <- cdj,
         :ok <- reject_duplicate(raw_id),
         {:ok, {auth_data, _attestation}} <- Wax.register(att_obj, cdj, challenge) do
      cose_key = auth_data.attested_credential_data.credential_public_key
      aaguid = auth_data.attested_credential_data.aaguid

      case Accounts.register_passkey(user, %{
             credential_id: raw_id,
             public_key: cose_key,
             sign_count: auth_data.sign_count || 0,
             aaguid: aaguid,
             label: params["label"]
           }) do
        {:ok, passkey} ->
          conn
          |> put_session(:webauthn_challenge, nil)
          |> json(%{success: true, id: passkey.id})

        {:error, changeset} ->
          conn
          |> put_status(422)
          |> json(%{error: "Failed to save credential", details: inspect(changeset.errors)})
      end
    else
      nil ->
        conn
        |> put_status(400)
        |> json(%{error: "No challenge in session. Please start again."})

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "Registration failed", reason: inspect(reason)})
    end
  end

  @doc """
  Returns PublicKeyCredentialRequestOptions for the authentication ceremony.

  If an `email` param is provided, only that user's passkeys are offered as
  `allowCredentials`. Otherwise the browser may use any discoverable credential.
  """
  def start_authentication(conn, params) do
    passkeys =
      if email = params["email"] do
        case Accounts.get_user_by_email(email) do
          %Accounts.User{} = user -> Accounts.list_user_passkeys(user)
          nil -> []
        end
      else
        []
      end

    allow_credentials =
      Enum.map(passkeys, fn pk ->
        {pk.credential_id, Passkey.decode_cose_key(pk.public_key)}
      end)

    challenge =
      if allow_credentials == [] do
        Wax.new_authentication_challenge(user_verification: "preferred")
      else
        Wax.new_authentication_challenge(
          allow_credentials: allow_credentials,
          user_verification: "preferred"
        )
      end

    options = %{
      publicKey: %{
        challenge: Base.url_encode64(challenge.bytes, padding: false),
        timeout: 120_000,
        rpId: challenge.rp_id,
        allowCredentials:
          Enum.map(passkeys, fn pk ->
            %{id: Base.url_encode64(pk.credential_id, padding: false), type: "public-key"}
          end),
        userVerification: "preferred"
      }
    }

    conn
    |> put_session(:webauthn_challenge, challenge)
    |> json(options)
  end

  @doc """
  Verifies the assertion response and logs the user in.

  Looks up the credential by ID, finds the owning user, verifies the
  signature via `Wax.authenticate/6`, updates the sign count, and
  establishes a session.
  """
  def finish_authentication(conn, params) do
    with challenge when not is_nil(challenge) <- get_session(conn, :webauthn_challenge),
         raw_id <- decode_param(params["rawId"] || params["id"]),
         {:ok, raw_id} <- raw_id,
         passkey when not is_nil(passkey) <- Accounts.get_passkey_by_credential_id(raw_id),
         {:ok, user} <- load_user(passkey),
         cdj <- decode_param(get_in(params, ["response", "clientDataJSON"])),
         {:ok, cdj} <- cdj,
         auth_data_bin <- decode_param(get_in(params, ["response", "authenticatorData"])),
         {:ok, auth_data_bin} <- auth_data_bin,
         sig <- decode_param(get_in(params, ["response", "signature"])),
         {:ok, sig} <- sig,
         cose_key <- Passkey.decode_cose_key(passkey.public_key),
         {:ok, auth_data} <-
           Wax.authenticate(raw_id, auth_data_bin, sig, cdj, challenge, [{raw_id, cose_key}]) do
      Accounts.update_passkey_sign_count(passkey, auth_data.sign_count)

      conn
      |> put_session(:webauthn_challenge, nil)
      |> YouWeb.UserAuth.log_in_user(user)
    else
      nil ->
        conn
        |> put_status(400)
        |> json(%{error: "No challenge in session. Please start again."})

      {:error, reason} ->
        conn
        |> put_status(401)
        |> json(%{error: "Authentication failed", reason: inspect(reason)})

      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "Authentication failed"})
    end
  end

  ## Passkey management (settings)

  @doc "Lists the user's registered passkeys."
  def index(conn, _params) do
    user = conn.assigns.current_scope.user
    passkeys = Accounts.list_user_passkeys(user)

    render(conn, :index, passkeys: passkeys)
  end

  @doc "Deletes a passkey, scoped to the owning user."
  def delete_passkey(conn, %{"id" => id}) do
    user = conn.assigns.current_scope.user

    case Accounts.delete_user_passkey(user, id) do
      {1, _} ->
        conn
        |> put_flash(:info, "Passkey removed.")
        |> redirect(to: ~p"/users/settings/passkeys")

      _ ->
        conn
        |> put_flash(:error, "Passkey not found.")
        |> redirect(to: ~p"/users/settings/passkeys")
    end
  end

  ## Helpers

  defp decode_param(nil), do: {:error, :missing}
  defp decode_param(""), do: {:error, :missing}

  defp decode_param(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  defp reject_duplicate(credential_id) do
    case Accounts.get_passkey_by_credential_id(credential_id) do
      nil -> :ok
      _ -> {:error, :duplicate_credential}
    end
  end

  defp load_user(%Passkey{user_id: user_id}) do
    case You.Repo.get(Accounts.User, user_id) do
      %Accounts.User{} = user -> {:ok, user}
      nil -> {:error, :user_not_found}
    end
  end
end
