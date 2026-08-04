defmodule You.CacheTest do
  @moduledoc """
  Settings and the single app are cached per node. Before #117 the only
  invalidation was in-process, so a second node kept serving the old value
  until it restarted.
  """
  use You.DataCase, async: false

  alias You.Settings

  @topic "you:cache"

  setup do
    # The cache is off under test, since the sandbox rolls writes back without
    # telling it. These tests are about the cache, so they turn it back on.
    Application.put_env(:you, :settings_cache, true)

    on_exit(fn ->
      Application.put_env(:you, :settings_cache, false)
      :persistent_term.erase({Settings, :jwt_expiry_hours})
      :persistent_term.erase({You.Mode, :app})
    end)

    :ok
  end

  describe "broadcasts" do
    test "a setting write tells the rest of the cluster" do
      Phoenix.PubSub.subscribe(You.PubSub, @topic)

      Settings.set(:jwt_expiry_hours, 9)

      assert_receive {:invalidate, {:setting, :jwt_expiry_hours}, origin}
      assert origin == node()
    end

    test "an app write tells the rest of the cluster" do
      Phoenix.PubSub.subscribe(You.PubSub, @topic)

      You.Mode.invalidate_app_cache()

      assert_receive {:invalidate, :single_app, _origin}
    end

    test "the writing node has already refreshed by the time it broadcasts" do
      Settings.set(:jwt_expiry_hours, 7)

      assert :persistent_term.get({Settings, :jwt_expiry_hours}) == 7
    end
  end

  describe "receiving" do
    test "an invalidation from another node refreshes the cached setting" do
      Settings.set(:jwt_expiry_hours, 3)
      :persistent_term.put({Settings, :jwt_expiry_hours}, 999)

      send(You.Cache, {:invalidate, {:setting, :jwt_expiry_hours}, :other@node})
      _ = :sys.get_state(You.Cache)

      assert :persistent_term.get({Settings, :jwt_expiry_hours}) == 3
    end

    test "an invalidation from another node drops the cached app" do
      :persistent_term.put({You.Mode, :app}, :stale)

      send(You.Cache, {:invalidate, :single_app, :other@node})
      _ = :sys.get_state(You.Cache)

      assert :persistent_term.get({You.Mode, :app}, :miss) == :miss
    end

    test "a node ignores its own broadcast, having already done the work" do
      :persistent_term.put({You.Mode, :app}, :sentinel)

      send(You.Cache, {:invalidate, :single_app, node()})
      _ = :sys.get_state(You.Cache)

      assert :persistent_term.get({You.Mode, :app}) == :sentinel
    end

    test "an unknown target does not take the notifier down" do
      send(You.Cache, {:invalidate, {:setting, :no_such_key}, :other@node})
      _ = :sys.get_state(You.Cache)

      assert Process.alive?(Process.whereis(You.Cache))
    end
  end
end
