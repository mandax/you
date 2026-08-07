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

  test "registers an app and lands on its page with the secret shown once", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/console/apps/new")

    {:ok, show_lv, html} =
      lv
      |> form("#new-app-form", %{
        "app" => %{
          "name" => "Billing",
          "slug" => "billing",
          "callback_url" => "https://billing.example.com/cb"
        }
      })
      |> render_submit()
      |> follow_redirect(conn)

    assert [app] = Admin.list_apps()
    assert app.slug == "billing"

    # Landed on the app's own page, on the credentials tab, with the secret
    # open in the dialog that marks it as shown once and unrepeatable.
    assert html =~ "Client secret"
    assert html =~ "never shown again"
    assert html =~ app.slug

    [dialog] = Regex.run(~r/<div id="app-secret"[^>]*>/, html)
    assert dialog =~ ~s(data-open="")

    # A fresh visit does not repeat it: the flash carrying it across the
    # redirect is one-shot, so a plain reload of the app page never has a
    # secret to show — the dialog renders present-but-closed, same as it
    # does for an app that was never just created.
    {:ok, _lv, html} = live(conn, ~p"/console/apps/#{app.slug}/credentials")
    [dialog] = Regex.run(~r/<div id="app-secret"[^>]*>/, html)
    refute dialog =~ ~s(data-open="")

    show_lv
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

      assert html =~ "is reserved and cannot be used"
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
      assert html =~ "Identity and URLs"
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
