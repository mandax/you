defmodule YouWeb.AppLive.NewTest do
  use YouWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias You.Admin

  setup %{conn: conn} do
    user = You.AccountsFixtures.user_fixture()
    Admin.promote_admin!(user)
    %{conn: log_in_user(conn, user), admin: user}
  end

  test "reachable directly by URL", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/console/apps/new")
    assert html =~ "Register app"
  end

  test "registers an app and reveals the secret on this page, once", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/new")

    html =
      lv
      |> form("#new-app-form", %{
        "app" => %{
          "name" => "Billing",
          "slug" => "billing",
          "callback_url" => "https://billing.example.com/cb",
          "first_party" => "true"
        }
      })
      |> render_submit()

    assert [app] = Admin.list_apps()
    assert app.slug == "billing"
    assert app.first_party

    # The secret is revealed in place, on the same page just submitted —
    # no navigation happens, so there is nothing to carry a credential
    # across in the first place.
    assert html =~ "Client secret"
    assert html =~ "never shown again"
    assert html =~ app.slug
    refute html =~ ~s(id="new-app-form")

    # The form is gone, so resubmitting (double-click, back-button replay)
    # cannot register a second app from the same page.
    refute lv |> has_element?("#new-app-form")

    # A link on to the app, not another copy of the secret anywhere else.
    assert lv |> has_element?(~s(a[href="/console/apps/#{app.slug}"]))

    # A fresh visit to the app's own page never has a secret to show — this
    # page never sends it anywhere for `AppLive.Show` to pick up. The
    # secret dialog's title/description render regardless of open state
    # (it is only ever hidden by the native <dialog>, not left out of the
    # DOM), so the thing to check is `data-open`, not the copy.
    {:ok, _lv, show_html} = live(conn, ~p"/console/apps/#{app.slug}/credentials")
    [dialog] = Regex.run(~r/<div id="app-secret"[^>]*>/, show_html)
    refute dialog =~ ~s(data-open="")
  end

  test "validation errors render on the page with entered values preserved", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/new")

    html =
      lv
      |> form("#new-app-form", %{
        "app" => %{
          "name" => "Missing Callback",
          "slug" => "missing-callback",
          "callback_url" => ""
        }
      })
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert Admin.list_apps() == []

    # Entered values survived the failed submit.
    assert html =~ "Missing Callback"
    assert html =~ "missing-callback"
  end

  # `color_input/1` renders a swatch alongside the hex field rather than a
  # plain `<.input>`, so it needs its own wiring to a form field to surface a
  # changeset error instead of silently reappearing with the value dropped.
  test "a rejected brand color renders its error and preserves the value", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/new")

    html =
      lv
      |> form("#new-app-form", %{
        "app" => %{
          "name" => "Bad Brand",
          "slug" => "bad-brand",
          "callback_url" => "https://bad-brand.example.com/cb",
          "brand_color" => "nope"
        }
      })
      |> render_submit()

    assert Admin.list_apps() == []
    assert html =~ "has invalid format"
    assert html =~ "nope"
  end

  describe "the new-as-a-slug collision" do
    test "new is reserved and cannot be registered as a slug", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/console/apps/new")

      html =
        lv
        |> form("#new-app-form", %{
          "app" => %{
            "name" => "New",
            "slug" => "new",
            "callback_url" => "https://new.example.com/cb"
          }
        })
        |> render_submit()

      assert html =~ "is reserved"
      assert Admin.list_apps() == []
    end

    test "a real slug still reaches the per-app page rather than this one", %{conn: conn} do
      {:ok, app, _secret} =
        Admin.create_app(%{
          slug: "reachable",
          name: "Reachable",
          callback_url: "https://reachable.example.com/cb"
        })

      {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}")

      refute html =~ "Register app"

      # "Identity and URLs" is a panel title on both pages; the tab strip is
      # what only `AppLive.Show` renders, so that is what actually tells
      # these two apart.
      assert html =~ "Credentials"
      assert html =~ "Members"
    end
  end

  test "a non-admin cannot reach the page" do
    conn =
      build_conn()
      |> log_in_user(You.AccountsFixtures.user_fixture())
      |> get(~p"/console/apps/new")

    assert conn.status == 404
  end

  test "an anonymous visitor cannot reach the page" do
    assert {:error, {:redirect, %{to: to}}} = live(build_conn(), ~p"/console/apps/new")
    assert to =~ "/users/log-in"
  end
end
