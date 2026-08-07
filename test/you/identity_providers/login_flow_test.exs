defmodule You.IdentityProviders.LoginFlowTest do
  @moduledoc """
  Unit coverage for the flow record that binds a federated login to the
  browser that started it (#132). The controller test exercises the same
  mechanism end-to-end over HTTP with real cookie jars; this file pins the
  context/schema behaviour each of those checks is built on, including the
  cases an HTTP test can't cheaply set up (a genuinely expired row).
  """

  use You.DataCase, async: true

  alias You.IdentityProviders
  alias You.IdentityProviders.LoginFlow
  alias You.Repo

  @ctx %{
    "callback_url" => "https://app.example.com/cb",
    "scopes" => ["email", "profile"],
    "code_challenge" => "abc123",
    "branding_app_slug" => "acme",
    "state" => "consumer-app-state-xyz"
  }

  describe "start_login_flow/2 and consume_login_flow/3" do
    test "a freshly started flow is consumed with its own state and nonce" do
      {state, nonce} = IdentityProviders.start_login_flow("google", @ctx)

      assert {:ok, ctx} = IdentityProviders.consume_login_flow("google", state, nonce)
      assert ctx == @ctx
    end

    test "the row stores the sha256 hash of state and nonce, never the raw value" do
      {state, nonce} = IdentityProviders.start_login_flow("google", @ctx)
      refute state == nonce

      flow = Repo.one!(LoginFlow)
      {:ok, decoded_state} = Base.url_decode64(state, padding: false)
      {:ok, decoded_nonce} = Base.url_decode64(nonce, padding: false)

      assert flow.state_hash == :crypto.hash(:sha256, decoded_state)
      assert flow.nonce_hash == :crypto.hash(:sha256, decoded_nonce)
    end

    test "consuming deletes the row: a second presentation of the same state is refused" do
      {state, nonce} = IdentityProviders.start_login_flow("google", @ctx)

      assert {:ok, _ctx} = IdentityProviders.consume_login_flow("google", state, nonce)
      assert Repo.aggregate(LoginFlow, :count) == 0

      assert {:error, :state_mismatch} =
               IdentityProviders.consume_login_flow("google", state, nonce)
    end

    test "consuming the same flow concurrently: exactly one succeeds, the loser gets a clean refusal" do
      {state, nonce} = IdentityProviders.start_login_flow("google", @ctx)

      parent_pid = self()

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent_pid, self())
            IdentityProviders.consume_login_flow("google", state, nonce)
          end)
        end

      results = Task.await_many(tasks)

      # A double-click on the IdP return, a browser retry, or a link
      # prefetch racing the real click all present the same `state` twice at
      # once. Only one may complete the login; the other must get the same
      # clean `:state_mismatch` refusal an ordinary replay gets — not a
      # crash from the two-step find-then-delete racing itself.
      assert Enum.count(results, &match?({:ok, _ctx}, &1)) == 1
      assert Enum.count(results, &match?({:error, :state_mismatch}, &1)) == 1
    end

    test "the correct nonce for a different flow's state is refused" do
      {state1, _nonce1} = IdentityProviders.start_login_flow("google", @ctx)
      {_state2, nonce2} = IdentityProviders.start_login_flow("google", @ctx)

      assert {:error, :state_mismatch} =
               IdentityProviders.consume_login_flow("google", state1, nonce2)

      # Consuming (and thus deleting) flow 1 with the wrong nonce still
      # spends it: single-use even on a failed attempt.
      assert {:error, :state_mismatch} =
               IdentityProviders.consume_login_flow("google", state1, "anything")
    end

    test "a missing nonce is refused, not a crash" do
      {state, _nonce} = IdentityProviders.start_login_flow("google", @ctx)

      assert {:error, :state_mismatch} =
               IdentityProviders.consume_login_flow("google", state, nil)
    end

    test "a state minted for a different provider is refused" do
      {state, nonce} = IdentityProviders.start_login_flow("google", @ctx)

      assert {:error, :state_mismatch} =
               IdentityProviders.consume_login_flow("github", state, nonce)
    end

    test "a tampered state is refused" do
      {state, nonce} = IdentityProviders.start_login_flow("google", @ctx)
      tampered = String.replace(state, ~r/[a-zA-Z0-9]/, "x", global: false)

      assert {:error, :state_mismatch} =
               IdentityProviders.consume_login_flow("google", tampered, nonce)
    end

    test "an unparseable state is refused, not raised" do
      assert {:error, :state_mismatch} =
               IdentityProviders.consume_login_flow("google", "not-valid-base64!!!", "nonce")
    end

    test "an expired flow is refused even with the right state and nonce" do
      {state, nonce} = IdentityProviders.start_login_flow("google", @ctx)

      past =
        DateTime.utc_now()
        |> DateTime.add(-(LoginFlow.validity_in_minutes() + 1) * 60, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(LoginFlow, set: [inserted_at: past])

      assert {:error, :state_mismatch} =
               IdentityProviders.consume_login_flow("google", state, nonce)
    end

    test "a flow just inside its validity window is still accepted" do
      {state, nonce} = IdentityProviders.start_login_flow("google", @ctx)

      recent =
        DateTime.utc_now()
        |> DateTime.add(-(LoginFlow.validity_in_minutes() - 1) * 60, :second)
        |> DateTime.truncate(:second)

      Repo.update_all(LoginFlow, set: [inserted_at: recent])

      assert {:ok, _ctx} = IdentityProviders.consume_login_flow("google", state, nonce)
    end
  end

  describe "cleanup_expired_login_flows/0" do
    test "deletes only expired rows" do
      {_state, _nonce} = IdentityProviders.start_login_flow("google", @ctx)

      past =
        DateTime.utc_now()
        |> DateTime.add(-(LoginFlow.validity_in_minutes() + 1) * 60, :second)
        |> DateTime.truncate(:second)

      Repo.insert!(%LoginFlow{
        state_hash: :crypto.strong_rand_bytes(32),
        nonce_hash: :crypto.strong_rand_bytes(32),
        provider: "google",
        ctx: "{}",
        inserted_at: past
      })

      assert Repo.aggregate(LoginFlow, :count) == 2

      IdentityProviders.cleanup_expired_login_flows()

      assert Repo.aggregate(LoginFlow, :count) == 1
    end
  end

  describe "sign_ctx/1 and verify_ctx/1" do
    test "round-trips" do
      signed = IdentityProviders.sign_ctx(@ctx)
      assert {:ok, ctx} = IdentityProviders.verify_ctx(signed)
      assert ctx == @ctx
    end

    test "a tampered ctx is refused" do
      signed = IdentityProviders.sign_ctx(@ctx)
      tampered = binary_part(signed, 0, byte_size(signed) - 1) <> "x"

      assert :error = IdentityProviders.verify_ctx(tampered)
    end

    test "garbage input is refused, not raised" do
      assert :error = IdentityProviders.verify_ctx("not-a-signed-token")
    end
  end
end
