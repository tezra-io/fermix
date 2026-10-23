defmodule FermixCore.Cues.BucketsTest do
  # async: false — Buckets owns named ETS tables and a registered name.
  use ExUnit.Case, async: false

  alias FermixCore.Cues.Buckets

  setup do
    start_supervised!(Buckets)
    :ok
  end

  describe "admit/3 (token buckets)" do
    test "a source starts with its burst of 100 and refills at 10 per second" do
      assert Buckets.admit("a", 100, 0) == 100
      assert Buckets.admit("a", 1, 0) == 0

      # 10 items a second: after 500 ms, five more.
      assert Buckets.admit("a", 10, 500) == 5
      assert Buckets.admit("a", 1, 500) == 0
    end

    test "a request beyond what is left is admitted in part" do
      assert Buckets.admit("a", 60, 0) == 60
      assert Buckets.admit("a", 60, 0) == 40
    end

    test "the source bucket never refills past its burst" do
      assert Buckets.admit("a", 100, 0) == 100
      assert Buckets.admit("a", 200, 3_600_000) == 100
    end

    test "the daemon-wide bucket bounds every source together at 50 a second" do
      assert Buckets.admit("a", 100, 0) == 100
      # Source b has its own full bucket, but the daemon's is spent.
      assert Buckets.admit("b", 10, 0) == 0
      # One second later the daemon has 50 more, and b may take them.
      assert Buckets.admit("b", 100, 1_000) == 50
      assert Buckets.admit("a", 5, 1_000) == 0
    end

    test "tokens/2 says what admit would give without spending it" do
      assert Buckets.tokens("a", 0) == 100
      assert Buckets.tokens("a", 0) == 100
      assert Buckets.admit("a", 98, 0) == 98
      assert Buckets.tokens("a", 0) == 2
      assert Buckets.tokens("b", 0) == 2
    end

    test "a clock that moves backwards refills nothing" do
      assert Buckets.admit("a", 100, 10_000) == 100
      assert Buckets.admit("a", 1, 5_000) == 0
    end
  end

  describe "acquire/2 and release/1 (door concurrency)" do
    test "at most 4 bodies are read at once for one source" do
      tokens = for _ <- 1..4, do: ok!(Buckets.acquire(:read, "a"))
      assert Buckets.acquire(:read, "a") == {:error, :busy}
      assert {:ok, _token} = Buckets.acquire(:read, "b")

      Buckets.release(hd(tokens))
      assert {:ok, _token} = Buckets.acquire(:read, "a")
    end

    test "at most 16 bodies are read at once in all" do
      for ref <- ~w(a b c d), _ <- 1..4, do: ok!(Buckets.acquire(:read, ref))
      assert Buckets.acquire(:read, "e") == {:error, :busy}

      assert Buckets.counts().read == %{
               all: 16,
               by_source: %{"a" => 4, "b" => 4, "c" => 4, "d" => 4}
             }
    end

    test "at most one authenticated request per source and four in all" do
      token = ok!(Buckets.acquire(:auth, "a"))
      assert Buckets.acquire(:auth, "a") == {:error, :busy}

      for ref <- ~w(b c d), do: ok!(Buckets.acquire(:auth, ref))
      assert Buckets.acquire(:auth, "e") == {:error, :busy}

      Buckets.release(token)
      assert {:ok, _token} = Buckets.acquire(:auth, "e")
    end

    test "read and authenticated slots are counted apart" do
      ok!(Buckets.acquire(:auth, "a"))
      assert {:ok, _token} = Buckets.acquire(:read, "a")
    end

    test "a release is idempotent and never takes a count below zero" do
      token = ok!(Buckets.acquire(:auth, "a"))
      Buckets.release(token)
      Buckets.release(token)
      Buckets.release(make_ref())

      assert Buckets.counts().auth == %{all: 0, by_source: %{}}
      assert {:ok, _token} = Buckets.acquire(:auth, "a")
    end

    test "a holder that dies gives its slots back" do
      test = self()

      holder =
        spawn(fn ->
          {:ok, _read} = Buckets.acquire(:read, "a")
          {:ok, _auth} = Buckets.acquire(:auth, "a")
          send(test, :held)

          receive do
            :never -> :ok
          end
        end)

      assert_receive :held
      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      # A call after the holder's exit is served after its :DOWN.
      assert Buckets.counts().auth == %{all: 0, by_source: %{}}
      assert Buckets.counts().read == %{all: 0, by_source: %{}}
    end

    test "a release with no Buckets running is a no-op" do
      token = ok!(Buckets.acquire(:auth, "a"))
      :ok = stop_supervised(Buckets)
      assert Buckets.release(token) == :ok
    end
  end

  describe "fingerprint/2 (credential fingerprints)" do
    test "loads once, keeps only the digest, and reloads after a minute" do
      test = self()

      load = fn ->
        send(test, :loaded)
        {:ok, "tok-1"}
      end

      digest = :crypto.hash(:sha256, "tok-1")

      assert Buckets.fingerprint({"a", :token}, now_ms: 0, load: load) == {:ok, digest}
      assert_received :loaded

      assert Buckets.fingerprint({"a", :token}, now_ms: 59_999, load: load) == {:ok, digest}
      refute_received :loaded

      refute :ets.tab2list(:fermix_cue_fingerprints) |> inspect() =~ "tok-1"

      assert Buckets.fingerprint({"a", :token}, now_ms: 60_000, load: load) == {:ok, digest}
      assert_received :loaded
    end

    test "a failed load is remembered for the same minute" do
      test = self()

      load = fn ->
        send(test, :loaded)
        {:error, :missing_secret}
      end

      assert Buckets.fingerprint({"a", :token}, now_ms: 0, load: load) ==
               {:error, :missing_secret}

      assert Buckets.fingerprint({"a", :token}, now_ms: 1_000, load: load) ==
               {:error, :missing_secret}

      assert_received :loaded
      refute_received :loaded
    end
  end

  describe "hook_key/2 (webhook signing keys)" do
    test "keeps the key itself a minute, apart from the fingerprints, failures included" do
      test = self()

      load = fn ->
        send(test, :loaded)
        {:ok, "signing-key-1"}
      end

      assert Buckets.hook_key({"gh", :secret}, now_ms: 0, load: load) == {:ok, "signing-key-1"}
      assert_received :loaded

      assert Buckets.hook_key({"gh", :secret}, now_ms: 59_999, load: load) ==
               {:ok, "signing-key-1"}

      refute_received :loaded
      refute :ets.tab2list(:fermix_cue_fingerprints) |> inspect() =~ "signing-key-1"

      assert Buckets.hook_key({"gh", :secret}, now_ms: 60_000, load: load) ==
               {:ok, "signing-key-1"}

      assert_received :loaded

      failing = fn ->
        send(test, :loaded)
        {:error, :missing_secret}
      end

      assert Buckets.hook_key({"std", :secret}, now_ms: 0, load: failing) ==
               {:error, :missing_secret}

      assert Buckets.hook_key({"std", :secret}, now_ms: 1_000, load: failing) ==
               {:error, :missing_secret}

      assert_received :loaded
      refute_received :loaded
    end

    test "with no Buckets running there is no key, and nothing is read" do
      :ok = stop_supervised(Buckets)
      load = fn -> flunk("read with no table") end
      assert Buckets.hook_key({"gh", :secret}, now_ms: 0, load: load) == {:error, :unavailable}
    end
  end

  describe "rejects" do
    test "are counted per source and reason, and taken once" do
      :ok = Buckets.record_reject("a", :unauthorized)
      :ok = Buckets.record_reject("a", :unauthorized)
      :ok = Buckets.record_reject("a", :rate_limited)
      :ok = Buckets.record_reject("b", :too_large)

      assert Buckets.take_rejects() == %{
               "a" => %{unauthorized: 2, rate_limited: 1},
               "b" => %{too_large: 1}
             }

      assert Buckets.take_rejects() == %{}
    end
  end

  test "a new Buckets starts every bucket and count afresh" do
    assert Buckets.admit("a", 100, 0) == 100
    ok!(Buckets.acquire(:auth, "a"))

    :ok = stop_supervised(Buckets)
    start_supervised!(Buckets)

    assert Buckets.admit("a", 100, 0) == 100
    assert {:ok, _token} = Buckets.acquire(:auth, "a")
  end

  defp ok!({:ok, token}), do: token
end
