defmodule You.ModeTest do
  use You.DataCase, async: false

  alias You.Admin
  alias You.Mode
  alias You.Repo

  # Mode is read from application config, so every test that wants single mode
  # sets it and puts it back. Not async for the same reason.
  defp single_mode(config) do
    Application.put_env(:you, :mode, :single)
    Application.put_env(:you, :single_app, config)

    on_exit(fn ->
      Application.put_env(:you, :mode, :multi)
      Application.delete_env(:you, :single_app)
    end)
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
      # The single app is the instance, so it can use the headless API.
      assert app.first_party
    end

    test "names the app after its slug when SINGLE_APP_NAME is unset" do
      single_mode(slug: "solo", callback_url: "https://solo.example.com/cb")

      assert :ok = Mode.Provisioner.run()
      assert Mode.app().name == "solo"
    end

    # The environment seeds the app; it does not own it. An operator who fixes
    # their callback URL in the console must not have it reverted by the next
    # `docker compose up`.
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

    # Nothing may be required to reach a login page: the epic's user has not
    # written their callback route yet.
    test "boots without a callback URL, pointing at this instance" do
      single_mode(slug: "solo", name: "Solo")

      assert :ok = Mode.Provisioner.run()

      assert Mode.app().callback_url == YouWeb.Endpoint.url() <> "/users/settings"
    end

    test "is a no-op in multi mode" do
      assert :ok = Mode.Provisioner.run()
      assert Repo.aggregate(Admin.App, :count) == 0
    end
  end
end
