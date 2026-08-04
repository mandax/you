defmodule You.ModeTest do
  use You.DataCase, async: false

  alias You.Admin
  alias You.Mode
  alias You.Repo

  defp single_mode(config) do
    You.Settings.set(:you_mode, "single")
    Application.put_env(:you, :single_app, config)

    on_exit(fn -> Application.delete_env(:you, :single_app) end)
  end

  describe "mode" do
    test "defaults to multi" do
      refute Mode.single?()
      assert Mode.mode() == :multi
      assert Mode.app_slug() == nil
      assert Mode.app() == nil
    end

    test "single mode exposes the configured slug" do
      single_mode(slug: "solo", callback_url: "https://solo.example.com/cb")

      assert Mode.single?()
      assert Mode.app_slug() == "solo"
    end
  end

  describe "provisioning" do
    test "creates the app from the environment" do
      single_mode(
        slug: "solo",
        name: "Solo",
        callback_url: "https://solo.example.com/cb",
        launch_url: "https://solo.example.com"
      )

      assert :ok = Mode.Provisioner.run()

      app = Mode.app()
      assert app.slug == "solo"
      assert app.name == "Solo"
      assert app.callback_url == "https://solo.example.com/cb"
      assert app.launch_url == "https://solo.example.com"
      assert app.first_party
    end

    test "names the app after its slug when SINGLE_APP_NAME is unset" do
      single_mode(slug: "solo", callback_url: "https://solo.example.com/cb")

      assert :ok = Mode.Provisioner.run()
      assert Mode.app().name == "solo"
    end

    test "never overwrites the console once the app exists" do
      single_mode(slug: "solo", name: "Solo", callback_url: "https://solo.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      {:ok, _} =
        Admin.update_app(Mode.app(), %{"callback_url" => "https://console.example.com/cb"})

      single_mode(slug: "solo", name: "Renamed", callback_url: "https://env.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      app = Mode.app()
      assert app.callback_url == "https://console.example.com/cb"
      assert app.name == "Solo"
      assert Repo.aggregate(Admin.App, :count) == 1
    end

    test "leaves console-managed fields alone" do
      single_mode(slug: "solo", name: "Solo", callback_url: "https://solo.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      {:ok, _} = Admin.update_app(Mode.app(), %{"brand_color" => "#7c3aed"})
      assert :ok = Mode.Provisioner.run()

      assert Mode.app().brand_color == "#7c3aed"
    end

    test "boots without a callback URL, pointing at this instance" do
      single_mode(slug: "solo", name: "Solo")

      assert :ok = Mode.Provisioner.run()

      assert Mode.app().callback_url == YouWeb.Endpoint.url() <> "/users/settings"
    end

    test "a changed slug never provisions a second app" do
      single_mode(slug: "solo", name: "Solo", callback_url: "https://solo.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      single_mode(slug: "renamed", name: "Solo", callback_url: "https://solo.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      assert Repo.aggregate(Admin.App, :count) == 1
      assert {:ok, _app} = Admin.lookup_app_by_callback("https://solo.example.com/cb")
    end

    test "resolves the app even when the configured slug has drifted" do
      single_mode(slug: "solo", name: "Solo", callback_url: "https://solo.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      single_mode(slug: "does-not-exist", callback_url: "https://solo.example.com/cb")

      assert %{slug: "solo"} = Mode.app()
    end

    test "is a no-op in multi mode" do
      assert :ok = Mode.Provisioner.run()
      assert Repo.aggregate(Admin.App, :count) == 0
    end
  end

  describe "app cache" do
    setup do
      Application.put_env(:you, :mode_app_cache, true)

      on_exit(fn ->
        Application.put_env(:you, :mode_app_cache, false)
        Mode.invalidate_app_cache()
      end)
    end

    test "a console update invalidates the cached app" do
      single_mode(slug: "solo", name: "Solo", callback_url: "https://solo.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      assert Mode.app().name == "Solo"

      {:ok, _} = Admin.update_app(Mode.app(), %{"name" => "Renamed"})

      assert Mode.app().name == "Renamed"
    end

    test "a console delete invalidates the cached app" do
      single_mode(slug: "solo", name: "Solo", callback_url: "https://solo.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      app = Mode.app()
      assert app.name == "Solo"

      {:ok, _} = Admin.delete_app(app)

      assert Mode.app() == nil
    end

    test "a secret rotation invalidates the cached app" do
      single_mode(slug: "solo", name: "Solo", callback_url: "https://solo.example.com/cb")
      assert :ok = Mode.Provisioner.run()

      hash_before = Mode.app().client_secret_hash

      {:ok, _app, _secret} = Admin.rotate_app_secret(Mode.app())

      refute Mode.app().client_secret_hash == hash_before
    end
  end
end
