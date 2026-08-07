defmodule YouWeb.ConsoleEmailTemplatesTest do
  @moduledoc """
  The Emails section: edit a template, and put it back to You's default.
  """
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.EmailTemplates

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    You.Admin.promote_admin!(user)
    You.Settings.set(:onboarding_completed, true)

    %{conn: log_in_user(conn, user)}
  end

  test "lists every template and marks the untouched ones as default", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/console/emails")

    for definition <- EmailTemplates.definitions() do
      assert html =~ definition.label
    end

    assert html =~ "default"
  end

  test "saving stores an override", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/emails")

    lv
    |> form("#email-template-magic_link", %{"subject" => "Meridian sign-in", "body" => "{{url}}"})
    |> render_submit()

    assert %{subject: "Meridian sign-in"} = EmailTemplates.get_override("magic_link")
  end

  test "a template missing its required placeholder is refused with a message", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/emails")

    html =
      lv
      |> form("#email-template-magic_link", %{"subject" => "Hi", "body" => "no link here"})
      |> render_submit()

    assert html =~ "{{url}}"
    assert EmailTemplates.get_override("magic_link") == nil
  end

  test "resetting drops the override", %{conn: conn} do
    {:ok, _} = EmailTemplates.upsert("magic_link", %{"subject" => "Custom", "body" => "{{url}}"})

    {:ok, lv, _html} = live(conn, ~p"/console/emails")

    lv
    |> element("button[phx-click='reset_email_template'][phx-value-key='magic_link']")
    |> render_click()

    assert EmailTemplates.get_override("magic_link") == nil
  end

  describe "tabs" do
    test "renders one tab per template, defaulting to the first", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console/emails")

      assert html =~ ~s(role="tablist")

      for definition <- EmailTemplates.definitions() do
        assert html =~ ~s(href="/console/emails/#{definition.key}")
      end

      first = hd(EmailTemplates.definitions())
      assert html =~ ~s(id="tabpanel-#{first.key}")
      assert html =~ ~s(id="email-template-#{first.key}")
      # The second template's form is not in the DOM at all while its tab is
      # inactive — this is what distinguishes real tabs from six stacked
      # sections that merely scroll past each other.
      second = Enum.at(EmailTemplates.definitions(), 1)
      refute html =~ ~s(id="email-template-#{second.key}")
    end

    test "the tab path segment selects the matching template", %{conn: conn} do
      target = Enum.at(EmailTemplates.definitions(), 1)

      {:ok, _lv, html} = live(conn, ~p"/console/emails/#{target.key}")

      assert html =~ ~s(id="email-template-#{target.key}")
      assert html =~ ~r/id="tab-#{target.key}"[^>]*aria-selected="true"/

      other = hd(EmailTemplates.definitions())
      refute html =~ ~s(id="email-template-#{other.key}")
    end

    test "an unknown tab falls back to the first template rather than blanking", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console/emails/bogus")

      first = hd(EmailTemplates.definitions())
      assert html =~ ~s(id="email-template-#{first.key}")
      assert html =~ ~r/id="tab-#{first.key}"[^>]*aria-selected="true"/
    end

    # `render_patch/2` does not do module lookup, so if `tab_strip` were ever
    # swapped for a `navigate`-based link this would still find an href and
    # pass on the string alone — the `data-phx-link="patch"` attribute is
    # what actually distinguishes a same-LiveView patch from a full redirect.
    test "the tab strip patches rather than redirecting", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/console/emails")

      target = Enum.at(EmailTemplates.definitions(), 1)
      assert html =~ ~s(href="/console/emails/#{target.key}" data-phx-link="patch")
    end

    test "saving one template's tab does not disturb an override on another", %{conn: conn} do
      [first, second | _] = EmailTemplates.definitions()

      {:ok, _} =
        EmailTemplates.upsert(second.key, %{"subject" => "Untouched", "body" => "{{url}}"})

      {:ok, lv, _html} = live(conn, ~p"/console/emails/#{first.key}")

      lv
      |> form("#email-template-#{first.key}", %{
        "subject" => "First template only",
        "body" => "{{url}}"
      })
      |> render_submit()

      assert %{subject: "First template only"} = EmailTemplates.get_override(first.key)
      assert %{subject: "Untouched"} = EmailTemplates.get_override(second.key)
    end

    test "switching tabs does not leak the previous tab's form into the next", %{conn: conn} do
      [first, second | _] = EmailTemplates.definitions()

      {:ok, lv, _html} = live(conn, ~p"/console/emails/#{first.key}")

      html =
        lv
        |> element("a[href='/console/emails/#{second.key}']")
        |> render_click()

      refute html =~ ~s(id="email-template-#{first.key}")
      assert html =~ ~s(id="email-template-#{second.key}")
    end

    test "the default badge and reset action stay per template", %{conn: conn} do
      [first, second | _] = EmailTemplates.definitions()
      {:ok, _} = EmailTemplates.upsert(second.key, %{"subject" => "Custom", "body" => "{{url}}"})

      {:ok, _lv, first_html} = live(conn, ~p"/console/emails/#{first.key}")
      assert first_html =~ "default"
      refute first_html =~ "Reset to default"

      {:ok, _lv, second_html} = live(conn, ~p"/console/emails/#{second.key}")
      refute second_html =~ "default</span>"
      assert second_html =~ "Reset to default"
    end
  end
end
