defmodule YouWeb.RateLimitTest do
  use ExUnit.Case, async: true

  alias YouWeb.RateLimit

  # A window-aligned start derived from the real clock, so entries written
  # by these tests are never expired when the periodic sweep runs.
  setup do
    window = 60_000
    now = System.monotonic_time(:millisecond)
    %{window: window, start: now - Integer.mod(now, window)}
  end

  test "allows requests up to the limit within a window", %{window: window, start: start} do
    bucket = {:test, make_ref()}

    assert {:allow, 1} = RateLimit.check(bucket, 2, window, now: start)
    assert {:allow, 2} = RateLimit.check(bucket, 2, window, now: start + 1)
  end

  test "denies requests over the limit with the remaining window as retry-after",
       %{window: window, start: start} do
    bucket = {:test, make_ref()}

    assert {:allow, 1} = RateLimit.check(bucket, 1, window, now: start)
    assert {:deny, retry_after} = RateLimit.check(bucket, 1, window, now: start + 5_000)
    assert retry_after == window - 5_000
  end

  test "the counter resets when the window rolls over", %{window: window, start: start} do
    bucket = {:test, make_ref()}

    assert {:allow, 1} = RateLimit.check(bucket, 1, window, now: start)
    assert {:deny, _} = RateLimit.check(bucket, 1, window, now: start)
    assert {:allow, 1} = RateLimit.check(bucket, 1, window, now: start + window)
  end

  test "buckets are independent", %{window: window, start: start} do
    assert {:allow, 1} = RateLimit.check({:test, make_ref()}, 1, window, now: start)
    assert {:allow, 1} = RateLimit.check({:test, make_ref()}, 1, window, now: start)
  end

  test "the sweep removes expired windows" do
    now = System.monotonic_time(:millisecond)
    bucket = {:test, make_ref()}

    assert {:allow, 1} = RateLimit.check(bucket, 1, 1_000, now: now - 10_000)
    assert {:deny, _} = RateLimit.check(bucket, 1, 1_000, now: now - 10_000)

    send(RateLimit, :sweep)
    _ = :sys.get_state(RateLimit)

    assert {:allow, 1} = RateLimit.check(bucket, 1, 1_000, now: now - 10_000)
  end
end
