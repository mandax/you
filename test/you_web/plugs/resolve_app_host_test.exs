defmodule YouWeb.Plugs.ResolveAppHostTest do
  @moduledoc """
  #121: a request whose `Host` matches no app takes the fail-closed
  unbranded path silently from `AuthMethods.app_for/1`'s point of view —
  this plug is where that gets a trace instead: structured, and sampled the
  same way `YouWeb.RequestURL`'s refused-host log is, so a scripted probe
  against many forged hosts can't flood it.
  """

  use YouWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias YouWeb.Plugs.ResolveAppHost

  defp enable_hostnames! do
    You.Settings.set(:hostname_template, "{label}.example.com")
    You.Settings.set(:feature_app_hostnames, true)

    on_exit(fn ->
      You.Settings.set(:feature_app_hostnames, false)
      You.Settings.set(:hostname_template, "")
    end)
  end

  defp call(conn), do: ResolveAppHost.call(conn, ResolveAppHost.init([]))

  describe "feature off" do
    test "no-op: no assign, no log" do
      log =
        capture_log(fn ->
          conn = call(%Plug.Conn{host: "unknown.example.net"})
          refute Map.has_key?(conn.assigns, :host_app)
        end)

      assert log == ""
    end
  end

  describe "feature on" do
    setup do
      enable_hostnames!()
      :ok
    end

    test "assigns the resolved app for its own host" do
      {:ok, app, _secret} =
        You.Admin.create_app(%{
          slug: "rah-#{System.unique_integer([:positive])}",
          name: "App",
          callback_url: "https://rah-#{System.unique_integer([:positive])}.example.com/cb",
          hostname_label: "rahost"
        })

      conn = call(%Plug.Conn{host: "rahost.example.com"})
      assert conn.assigns.host_app.id == app.id
    end

    test "assigns nil for the canonical host, and logs nothing" do
      log =
        capture_log(fn ->
          conn = call(%Plug.Conn{host: YouWeb.Endpoint.host()})
          assert conn.assigns.host_app == nil
        end)

      refute log =~ "unresolved app host"
    end

    test "an unresolved host is logged, sampled by a hash of the host" do
      host = "probe-#{System.unique_integer([:positive])}.example.net"

      log =
        capture_log(fn ->
          conn = call(%Plug.Conn{host: host})
          assert conn.assigns.host_app == nil
        end)

      assert log =~ "unresolved app host"
      assert log =~ host
    end

    test "a repeat request for the same unresolved host within the window logs once" do
      host = "probe-repeat-#{System.unique_integer([:positive])}.example.net"

      log =
        capture_log(fn ->
          call(%Plug.Conn{host: host})
          call(%Plug.Conn{host: host})
        end)

      assert Enum.count(String.split(log, "unresolved app host")) - 1 == 1
    end
  end
end
