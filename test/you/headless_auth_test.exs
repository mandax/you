defmodule You.HeadlessAuthTest do
  use You.DataCase, async: false

  alias You.AccountsFixtures

  defp first_party_app do
    {:ok, app, secret} =
      You.Admin.create_app(%{
        slug: "fp-#{System.unique_integer([:positive])}",
        name: "First Party",
        callback_url: "https://fp.example.com/cb",
        first_party: true
      })

    {app, secret}
  end

  defp call(client_id, secret, params),
    do: GenServer.call(You.IAM.Server, {:password_login, client_id, secret, params})

  describe "password_login (headless grant)" do
    test "first-party app + valid credentials returns a token bundle" do
      {app, secret} = first_party_app()
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      assert {:ok, bundle} =
               call(app.slug, secret, %{
                 email: user.email,
                 password: AccountsFixtures.valid_user_password(),
                 scopes: ["email", "roles"]
               })

      assert bundle.user_id == user.id
      assert bundle.email == user.email
      assert is_binary(bundle.jwt)
      assert is_binary(bundle.refresh_token)
    end

    test "a non-first-party app is refused" do
      {:ok, app, secret} =
        You.Admin.create_app(%{
          slug: "third-party",
          name: "Third",
          callback_url: "https://tp.example.com/cb"
        })

      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      assert {:error, :not_first_party} =
               call(app.slug, secret, %{
                 email: user.email,
                 password: AccountsFixtures.valid_user_password()
               })
    end

    test "wrong client secret is invalid_client" do
      {app, _secret} = first_party_app()
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      assert {:error, :invalid_client} =
               call(app.slug, "wrong-secret", %{
                 email: user.email,
                 password: AccountsFixtures.valid_user_password()
               })
    end

    test "unknown client is invalid_client" do
      assert {:error, :invalid_client} =
               call("nope", "nope", %{email: "a@b.c", password: "whatever12345"})
    end

    test "wrong password is invalid_credentials (does not leak client validity)" do
      {app, secret} = first_party_app()
      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()

      assert {:error, :invalid_credentials} =
               call(app.slug, secret, %{email: user.email, password: "wrong-password"})
    end

    test "an MFA-enabled user without a code returns mfa_required" do
      {app, secret} = first_party_app()

      user =
        AccountsFixtures.user_fixture()
        |> AccountsFixtures.set_password()

      {:ok, user} =
        user
        |> Ecto.Changeset.change(totp_enabled: true, totp_secret: NimbleTOTP.secret())
        |> Repo.update()

      assert {:error, :mfa_required} =
               call(app.slug, secret, %{
                 email: user.email,
                 password: AccountsFixtures.valid_user_password()
               })

      # correct TOTP completes the login
      code = NimbleTOTP.verification_code(user.totp_secret)

      assert {:ok, _bundle} =
               call(app.slug, secret, %{
                 email: user.email,
                 password: AccountsFixtures.valid_user_password(),
                 totp_code: code
               })
    end
  end
end
