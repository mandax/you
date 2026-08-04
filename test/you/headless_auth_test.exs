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

    test "an email-2FA user is challenged rather than signed straight in" do
      {app, secret} = first_party_app()

      user = AccountsFixtures.user_fixture() |> AccountsFixtures.set_password()
      {:ok, user} = You.Accounts.enable_email_2fa(user)

      assert {:error, :mfa_required} =
               call(app.slug, secret, %{
                 email: user.email,
                 password: AccountsFixtures.valid_user_password()
               })

      code = issue_email_2fa_code(user)

      assert {:ok, _bundle} =
               call(app.slug, secret, %{
                 email: user.email,
                 password: AccountsFixtures.valid_user_password(),
                 email_2fa_code: code
               })
    end

    # The refusal above sends its code from inside You.IAM.Server, so that email
    # lands in the server's mailbox and not the test's. Reissuing from here puts
    # an equivalent code where it can be read.
    defp issue_email_2fa_code(user) do
      :ok = You.Accounts.send_email_2fa_code(user)
      assert_receive {:email, %{subject: "Your verification code", text_body: body}}
      [code] = Regex.run(~r/\b\d{6}\b/, body)
      code
    end
  end

  describe "register (headless sign-up grant)" do
    test "first-party app + valid params creates an unconfirmed user and returns a bundle" do
      {app, secret} = first_party_app()
      email = AccountsFixtures.unique_user_email()
      password = AccountsFixtures.valid_user_password()

      assert {:ok, bundle} =
               GenServer.call(
                 You.IAM.Server,
                 {:register, app.slug, secret,
                  %{
                    email: email,
                    password: password,
                    scopes: ["email"]
                  }}
               )

      assert bundle.user_id
      assert bundle.email == email
      assert is_binary(bundle.jwt)
      assert is_binary(bundle.refresh_token)

      # The user must be unconfirmed.
      user = Repo.get!(You.Accounts.User, bundle.user_id)
      assert is_nil(user.confirmed_at)
    end

    test "duplicate email is :email_taken" do
      {app, secret} = first_party_app()
      email = AccountsFixtures.unique_user_email()

      # First registration succeeds.
      assert {:ok, _} =
               GenServer.call(
                 You.IAM.Server,
                 {:register, app.slug, secret,
                  %{
                    email: email,
                    password: AccountsFixtures.valid_user_password()
                  }}
               )

      # Second with same email fails.
      assert {:error, :email_taken} =
               GenServer.call(
                 You.IAM.Server,
                 {:register, app.slug, secret,
                  %{
                    email: email,
                    password: AccountsFixtures.valid_user_password()
                  }}
               )
    end

    test "short password is :invalid_registration" do
      {app, secret} = first_party_app()

      assert {:error, :invalid_registration} =
               GenServer.call(
                 You.IAM.Server,
                 {:register, app.slug, secret,
                  %{
                    email: AccountsFixtures.unique_user_email(),
                    password: "short"
                  }}
               )
    end

    test "a non-first-party app is refused" do
      {:ok, app, secret} =
        You.Admin.create_app(%{
          slug: "tp-reg-#{System.unique_integer([:positive])}",
          name: "Third Party",
          callback_url: "https://tp.example.com/cb"
        })

      assert {:error, :not_first_party} =
               GenServer.call(
                 You.IAM.Server,
                 {:register, app.slug, secret,
                  %{
                    email: AccountsFixtures.unique_user_email(),
                    password: AccountsFixtures.valid_user_password()
                  }}
               )
    end

    test "wrong client secret is invalid_client" do
      {app, _secret} = first_party_app()

      assert {:error, :invalid_client} =
               GenServer.call(
                 You.IAM.Server,
                 {:register, app.slug, "wrong-secret",
                  %{
                    email: AccountsFixtures.unique_user_email(),
                    password: AccountsFixtures.valid_user_password()
                  }}
               )
    end
  end
end
