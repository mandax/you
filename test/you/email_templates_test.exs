defmodule You.EmailTemplatesTest do
  @moduledoc """
  UserNotifier's copy was compiled in, so every instance's magic link,
  confirmation, reset and 2FA emails went out in You's own voice on mail the
  operator's users receive.
  """
  use You.DataCase, async: false

  alias You.Accounts
  alias You.EmailTemplates

  import You.AccountsFixtures

  describe "rendering" do
    test "falls back to the compiled-in default" do
      {subject, body} = EmailTemplates.render("magic_link", %{email: "a@b.c", url: "https://x"})

      assert subject == "Log in instructions"
      assert body =~ "https://x"
      assert body =~ "a@b.c"
    end

    test "an override replaces it" do
      {:ok, _} =
        EmailTemplates.upsert("magic_link", %{
          "subject" => "Your Meridian sign-in link",
          "body" => "Tap here: {{url}}"
        })

      {subject, body} = EmailTemplates.render("magic_link", %{url: "https://x"})

      assert subject == "Your Meridian sign-in link"
      assert body == "Tap here: https://x"
    end

    test "a placeholder with nothing to fill it is left as written, not blanked" do
      {:ok, _} =
        EmailTemplates.upsert("magic_link", %{"subject" => "Hi", "body" => "{{url}} {{nope}}"})

      {_subject, body} = EmailTemplates.render("magic_link", %{url: "https://x"})

      assert body == "https://x {{nope}}"
    end

    test "an unknown template is a programming error, not a silent empty email" do
      assert_raise ArgumentError, fn -> EmailTemplates.render("no_such_template") end
    end

    test "every declared template renders with its declared variables" do
      for definition <- EmailTemplates.definitions() do
        assigns = Map.new(definition.variables, &{&1, "x-#{&1}"})
        {subject, body} = EmailTemplates.render(definition.key, assigns)

        assert is_binary(subject) and subject != ""
        assert is_binary(body) and body != ""
        refute body =~ "{{"
      end
    end
  end

  describe "validation" do
    test "a magic link without its URL is refused" do
      assert {:error, changeset} =
               EmailTemplates.upsert("magic_link", %{
                 "subject" => "Hi",
                 "body" => "Just sign in, you know how"
               })

      assert %{body: [message]} = errors_on(changeset)
      assert message =~ "{{url}}"
    end

    test "a 2FA email without its code is refused" do
      assert {:error, changeset} =
               EmailTemplates.upsert("email_2fa", %{"subject" => "Hi", "body" => "No code here"})

      assert %{body: [_ | _]} = errors_on(changeset)
    end

    test "the required placeholder may live in the subject" do
      assert {:ok, _} =
               EmailTemplates.upsert("email_2fa", %{
                 "subject" => "Your code is {{code}}",
                 "body" => "That's it."
               })
    end

    test "a blank subject or body is refused" do
      assert {:error, _} =
               EmailTemplates.upsert("magic_link", %{"subject" => "", "body" => "{{url}}"})
    end

    test "a key You does not send is refused" do
      assert {:error, :unknown_template} =
               EmailTemplates.upsert("newsletter", %{"subject" => "Hi", "body" => "Hello"})
    end
  end

  describe "reset" do
    test "deletes the override so the template tracks the default again" do
      {:ok, _} =
        EmailTemplates.upsert("magic_link", %{"subject" => "Custom", "body" => "{{url}}"})

      assert :ok = EmailTemplates.reset("magic_link")
      assert EmailTemplates.get_override("magic_link") == nil

      {subject, _body} = EmailTemplates.render("magic_link", %{url: "https://x"})
      assert subject == "Log in instructions"
    end

    test "is fine when there was no override" do
      assert :ok = EmailTemplates.reset("reset_password")
    end
  end

  describe "the mail that actually goes out" do
    test "a magic link uses the override" do
      {:ok, _} =
        EmailTemplates.upsert("magic_link", %{
          "subject" => "Meridian sign-in",
          "body" => "Go: {{url}}"
        })

      # user_fixture/0 confirms the account by sending and consuming a magic
      # link, so its own email is already in the mailbox — match on the subject
      # rather than taking whatever arrived first.
      user = user_fixture()
      Accounts.deliver_login_instructions(user, &"https://you.example.com/#{&1}")

      assert_receive {:email, %{subject: "Meridian sign-in", text_body: body}}
      assert body =~ "Go: https://you.example.com/"
    end

    test "an unconfirmed user gets the confirmation template, not the magic link" do
      {:ok, _} =
        EmailTemplates.upsert("confirmation", %{
          "subject" => "Confirm your Meridian account",
          "body" => "{{url}}"
        })

      user = unconfirmed_user_fixture()
      Accounts.deliver_login_instructions(user, &"https://you.example.com/#{&1}")

      assert_receive {:email, %{subject: "Confirm your Meridian account"}}
    end

    test "the 2FA code email uses the override" do
      {:ok, _} =
        EmailTemplates.upsert("email_2fa", %{
          "subject" => "Meridian code",
          "body" => "Code: {{code}}"
        })

      user = user_fixture()
      :ok = Accounts.send_email_2fa_code(user)

      assert_receive {:email, %{subject: "Meridian code", text_body: body}}
      assert body =~ ~r/Code: \d{6}/
    end
  end

  describe "configuration bundles" do
    test "carry the overrides and nothing else" do
      {:ok, _} =
        EmailTemplates.upsert("magic_link", %{"subject" => "Custom", "body" => "{{url}}"})

      exported = You.Config.Bundle.export()["email_templates"]

      assert [%{"key" => "magic_link", "subject" => "Custom"}] = exported
    end

    test "an imported override applies" do
      payload = %{
        "version" => 1,
        "email_templates" => [
          %{"key" => "reset_password", "subject" => "Reset it", "body" => "{{url}}"}
        ]
      }

      assert {:ok, summary} = You.Config.Bundle.import(payload)
      assert summary.email_templates == 1

      {subject, _body} = EmailTemplates.render("reset_password", %{url: "https://x"})
      assert subject == "Reset it"
    end

    test "a bundle carrying an unknown template does not blow up the import" do
      payload = %{
        "version" => 1,
        "email_templates" => [%{"key" => "newsletter", "subject" => "Hi", "body" => "Hello"}]
      }

      assert {:ok, summary} = You.Config.Bundle.import(payload)
      assert summary.email_templates == 0
    end
  end
end
