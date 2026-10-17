defmodule FermixCore.Management.XTest do
  @moduledoc """
  The `x.*` adapter: the atom-keyed facts the shared X handle channel answers
  with become the fixed-record wire, and every sentence on it is this module's.

  The provider is a fake that answers whatever the case hands it through the
  provider's own options, so no case starts the channel, dials Fermix Connect or
  reads global state.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Management.X

  defmodule FakeProvider do
    @moduledoc false

    def status(opts), do: answer(opts)

    def pair_start(origin, opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:pair_start, origin})
      answer(opts)
    end

    def pair_get(_session_id, opts), do: answer(opts)
    def pair_paste(_session_id, _url, opts), do: answer(opts)
    def pair_cancel(_session_id, opts), do: answer(opts)
    def unpair(opts), do: answer(opts)

    defp answer(opts) do
      case Keyword.fetch!(opts, :reply) do
        reply when is_function(reply, 0) -> reply.()
        reply -> reply
      end
    end
  end

  @session_id "9a1d4c7e-2b3f-4e5a-8c6d-0f1e2d3c4b5a"
  @instance_id "ins_5c8e1a2b9d40"
  @origin "https://connect.fermix.ai"
  @fingerprint "3f9a 1c2e 7b4d 05a8 9e61 c4b2 0d7f 5a33 81e6 2f0c 9b47 d15e 6a08 c3f2 47b9 e05d"
  @session_keys ~w(failure handle origin session_id state ttl_ms)
  @authorize_url "https://connect.fermix.ai/confirm/EXAMPLE?response_type=code&state=EXAMPLE"
  @callback_url "http://127.0.0.1:53682/callback?code=EXAMPLE&state=EXAMPLE"
  @status_keys ~w(connection enabled last_failure paired pairing pending refusal running)
  @unavailable {:error, {:unavailable, "x"}}

  describe "the session view" do
    test "every state renders every field, null where it does not apply" do
      for {state, session} <- every_state() do
        assert {:ok, view} = X.pair_get(@session_id, fake({:ok, session}))

        assert Enum.sort(Map.keys(view)) == @session_keys, "#{state} is not a fixed record"
        assert view["state"] == Atom.to_string(state)
        assert view["session_id"] == @session_id
        assert view["origin"] == @origin
      end
    end

    test "a session waiting for the owner's browser has a countdown and nothing else" do
      assert {:ok, view} = X.pair_get(@session_id, fake({:ok, session(:awaiting_browser)}))

      assert view == %{
               "session_id" => @session_id,
               "state" => "awaiting_browser",
               "ttl_ms" => 540_000,
               "origin" => @origin,
               "handle" => nil,
               "failure" => nil
             }
    end

    test "an approved session names the X account Connect paired and clears the countdown" do
      session = session(:approved, ttl_ms: nil, handle: "@sam_at_home")

      assert {:ok, view} = X.pair_get(@session_id, fake({:ok, session}))

      assert view["handle"] == "@sam_at_home"
      assert view["ttl_ms"] == nil
      assert view["failure"] == nil
    end

    test "a pasted address answers the session as it stands" do
      assert {:ok, view} =
               X.pair_paste(@session_id, @callback_url, fake({:ok, session(:awaiting_browser)}))

      assert view["state"] == "awaiting_browser"
      assert Enum.sort(Map.keys(view)) == @session_keys
    end

    test "a failed session carries the daemon's own sentence for each reason" do
      for {reason, {code, sentence}} <- session_failures() do
        session = session(:failed, ttl_ms: nil, failure: %{reason: reason})

        assert {:ok, view} = X.pair_get(@session_id, fake({:ok, session}))

        assert view["failure"] == %{"code" => code, "sentence" => sentence}
        assert sentence in X.sentences()
      end
    end

    test "a failure reason the contract does not name is refused loudly" do
      session = session(:failed, ttl_ms: nil, failure: %{reason: :surprise})

      assert_raise FunctionClauseError, fn ->
        X.pair_get(@session_id, fake({:ok, session}))
      end
    end

    test "a state or a handle the contract does not name is refused loudly" do
      for state <- [:awaiting_scan, :awaiting_decision, :awaiting_confirmation] do
        assert_raise FunctionClauseError, fn ->
          X.pair_get(@session_id, fake({:ok, session(state)}))
        end
      end

      assert_raise FunctionClauseError, fn ->
        X.pair_get(@session_id, fake({:ok, session(:approved, handle: %{handle: "@sam"})}))
      end
    end
  end

  describe "opening a pairing session" do
    test "answers the session plus the authorization link, once" do
      reply = {:ok, %{session: session(:awaiting_browser), confirm_url: @authorize_url}}

      assert {:ok, view} = X.pair_start(nil, fake(reply))

      assert Enum.sort(Map.keys(view)) == Enum.sort(["confirm_url" | @session_keys])
      assert view["confirm_url"] == @authorize_url
      assert view["state"] == "awaiting_browser"
    end

    test "no origin dials the daemon's own Connect, and a named one is passed through" do
      reply = {:ok, %{session: session(:awaiting_browser), confirm_url: "https://c/x"}}

      assert {:ok, _view} = X.pair_start(nil, fake(reply, test_pid: self()))
      assert_received {:pair_start, "https://connect.fermix.ai"}
      assert X.default_origin() == "https://connect.fermix.ai"

      staging = "https://staging.connect.fermix.ai:8443"
      assert {:ok, _view} = X.pair_start(staging, fake(reply, test_pid: self()))
      assert_received {:pair_start, ^staging}
    end

    # Every signature names the origin, so only a scheme and a host can be one.
    test "an origin that is not an https host alone is refused before anything is dialed" do
      sentence = "The Fermix Connect address must be an https address with a host and no path."

      for origin <- [
            "http://connect.fermix.ai",
            "https://connect.fermix.ai/",
            "https://connect.fermix.ai/v1",
            "https://connect.fermix.ai?x=1",
            "https://user@connect.fermix.ai",
            "https://Connect.Fermix.ai",
            "https://",
            "connect.fermix.ai",
            "https://" <> String.duplicate("a", 300)
          ] do
        assert X.pair_start(origin, fake({:ok, :never}, test_pid: self())) ==
                 {:error, {:invalid_params, "origin", sentence}},
               "#{origin} was accepted"
      end

      refute_received {:pair_start, _origin}
      assert sentence in X.sentences()
    end

    # The origin a pairing names is the one every Connect signature names, so the
    # adapter's rule and the Connect contract's `origin` shape are one rule.
    test "an origin is accepted exactly when the Connect contract's shape admits it" do
      pattern =
        :fermix_core
        |> Application.app_dir("priv/connect/protocol.schema.json")
        |> File.read!()
        |> Jason.decode!()
        |> get_in(["$defs", "origin", "pattern"])
        |> Regex.compile!()

      reply = {:ok, %{session: session(:awaiting_browser), confirm_url: "https://c/x"}}

      for origin <- [
            "https://connect.fermix.ai",
            "https://staging.connect.fermix.ai:8443",
            "https://localhost:4443",
            "https://Connect.fermix.ai",
            "https://connect.fermix.ai/",
            "https://-bad.fermix.ai",
            "http://connect.fermix.ai",
            "https://connect.fermix.ai:"
          ] do
        accepted? = match?({:ok, _view}, X.pair_start(origin, fake(reply)))
        assert accepted? == Regex.match?(pattern, origin), "#{origin} disagrees with the contract"
      end
    end

    test "a session already open is busy, and nothing else is" do
      assert X.pair_start(nil, fake({:error, :pairing_active})) == {:error, {:busy, "x.pair"}}
    end

    # Nothing was opened, so there is no session to poll and no link to show.
    test "a refusal with a sentence is a failed view that opened nothing" do
      for {reason, {code, sentence}} <- session_failures() do
        assert {:ok, view} = X.pair_start(nil, fake({:error, reason}))
        assert view == failed_start(code, sentence), "#{reason} did not answer a failed view"
      end
    end

    test "any other refusal is logged and answered with the fixed sentence" do
      log =
        capture_log(fn ->
          assert {:ok, view} = X.pair_start(nil, fake({:error, {:enoent, "/Users/sam/.fermix"}}))

          assert view ==
                   failed_start("internal_error", "Pairing could not start. See the daemon log.")
        end)

      assert log =~ "pairing session refused"
      assert log =~ ":enoent"
    end

    test "a malformed success is refused without logging the link it carried" do
      no_session = %{confirm_url: "https://connect.fermix.ai/pair?token=SHOULD-NOT-LOG"}

      oversized = %{
        session: session(:awaiting_browser),
        confirm_url: String.duplicate("x", 2_049)
      }

      log =
        capture_log(fn ->
          assert X.pair_start(nil, fake({:ok, no_session})) == @unavailable
          assert X.pair_start(nil, fake({:ok, oversized})) == @unavailable
        end)

      refute log =~ "SHOULD-NOT-LOG"
      assert log =~ "pair_start answered a shape"
    end
  end

  describe "refusals on an open session" do
    test "a session this daemon does not retain names the id it was asked for" do
      reply = {:error, :unknown_pairing_session}
      gone = "0d9e8f7a-6b5c-4d3e-8f2a-1b0c9d8e7f6a"

      assert X.pair_get(gone, fake(reply)) == {:error, {:unknown_pairing_session, gone}}

      assert X.pair_paste(gone, @callback_url, fake(reply)) ==
               {:error, {:unknown_pairing_session, gone}}

      assert X.pair_cancel(gone, fake(reply)) == {:error, {:unknown_pairing_session, gone}}
    end

    test "a paste to a session no longer waiting is refused in the daemon's words" do
      sentence = "This pairing is no longer waiting for the browser."

      assert X.pair_paste(@session_id, @callback_url, fake({:error, :pairing_not_waiting})) ==
               {:error, {:invalid_params, "session_id", sentence}}

      assert sentence in X.sentences()
    end

    test "a refusal the contract does not name is logged and answered unavailable" do
      log =
        capture_log(fn ->
          assert X.pair_paste(@session_id, @callback_url, fake({:error, :surprise})) ==
                   @unavailable
        end)

      assert log =~ "pair_paste refused"
      refute log =~ "EXAMPLE"
    end
  end

  describe "unpairing" do
    test "answers the instance it unpaired" do
      assert X.unpair(fake({:ok, %{instance_id: @instance_id}})) ==
               {:ok, %{"instance_id" => @instance_id, "unpaired" => true}}
    end

    test "nothing paired, or Connect out of reach, is unavailable with a sentence" do
      assert X.unpair(fake({:error, :not_paired})) ==
               {:error, {:unavailable, "x", "This Fermix is not paired with Fermix Connect."}}

      assert {:error, {:unavailable, "x", sentence}} =
               X.unpair(fake({:error, :connect_unreachable}))

      assert sentence ==
               "Fermix Connect could not be reached, so this Fermix is still paired. " <>
                 "Try again later."

      assert sentence in X.sentences()
    end
  end

  describe "the channel status" do
    test "every field is published, with the pairing and the session in flight" do
      assert {:ok, view} = X.status(fake({:ok, status()}))

      assert Enum.sort(Map.keys(view)) == @status_keys

      assert view == %{
               "enabled" => true,
               "paired" => %{
                 "instance_id" => @instance_id,
                 "handle" => "@sam_at_home",
                 "fingerprint" => @fingerprint,
                 "origin" => @origin,
                 "tenant_generation" => 1,
                 "paired_at" => "2026-10-16T05:00:00Z"
               },
               "connection" => "connected",
               "refusal" => nil,
               "pending" => 1,
               "running" => 1,
               "last_failure" => %{
                 "at" => "2026-10-16T04:58:12Z",
                 "sentence" => "The connection to Fermix Connect was lost."
               },
               "pairing" => %{"session_id" => @session_id, "state" => "approved"}
             }
    end

    test "a channel that is off still answers, with nothing paired and no connection" do
      off = %{
        status()
        | enabled: false,
          paired: nil,
          connection: :off,
          pending: 0,
          running: 0,
          last_failure: nil,
          pairing: nil
      }

      assert {:ok, view} = X.status(fake({:ok, off}))

      assert view["connection"] == "off"
      assert view["paired"] == nil and view["pairing"] == nil and view["last_failure"] == nil
    end

    test "every connection state is published by its word" do
      for connection <- ~w(off refused connecting connected down)a do
        assert {:ok, view} = X.status(fake({:ok, %{status() | connection: connection}}))
        assert view["connection"] == Atom.to_string(connection)
      end
    end

    test "a refused channel names its reason and the daemon's sentence" do
      refusals = [
        not_paired: "The X channel is on, but this Fermix is not paired with Fermix Connect.",
        pairing_invalid: "The pairing record could not be read. Unpair and pair again.",
        memory_disabled: "The X channel keeps its work in the memory store, which is turned off.",
        proxy_unsupported:
          "The X channel cannot reach Fermix Connect through the configured proxy yet.",
        revoked: "Fermix Connect no longer accepts this Fermix. Unpair and pair again."
      ]

      for {reason, sentence} <- refusals do
        refused = %{status() | connection: :refused, refusal: reason}

        assert {:ok, view} = X.status(fake({:ok, refused}))
        assert view["refusal"] == %{"reason" => Atom.to_string(reason), "sentence" => sentence}
        assert sentence in X.sentences()
      end
    end

    test "every last failure is said in the daemon's words, never the channel's" do
      for reason <- ~w(connect_failed auth_failed connection_lost replaced rate_limited
                       malformed restarting expired assignment_rejected turn_failed
                       result_rejected)a do
        failed = %{status() | last_failure: %{at: "2026-10-16T04:58:12Z", reason: reason}}

        assert {:ok, %{"last_failure" => %{"sentence" => sentence}}} =
                 X.status(fake({:ok, failed}))

        assert sentence in X.sentences()
      end
    end

    test "a word the contract does not name is refused loudly" do
      assert_raise FunctionClauseError, fn ->
        X.status(fake({:ok, %{status() | connection: :sleeping}}))
      end

      assert_raise KeyError, fn ->
        X.status(fake({:ok, %{status() | refusal: :surprise}}))
      end

      assert_raise FunctionClauseError, fn ->
        X.status(fake({:ok, %{status() | pending: -1}}))
      end
    end
  end

  describe "a provider that cannot answer" do
    test "no provider at all is the capability being unavailable" do
      capture_log(fn ->
        assert X.status(provider: nil) == @unavailable
        assert X.pair_start(nil, provider: nil) == @unavailable
        assert X.unpair(provider: nil) == @unavailable
      end)
    end

    test "a provider without the function is unavailable rather than a crash" do
      capture_log(fn ->
        assert X.pair_get(@session_id, provider: Enum) == @unavailable
        assert X.status(provider: Enum) == @unavailable
      end)
    end

    # The channel is a process tree in another app. Its exit reason names that
    # app's internals, so it goes to the log and never onto the wire.
    test "a call that exits is logged, redacted, and answered unavailable" do
      exits = fn -> exit({:timeout, {GenServer, :call, [:x_pairing, :status]}}) end

      log = capture_log(fn -> assert X.status(fake(exits)) == @unavailable end)

      assert log =~ "status exited"
      assert log =~ ":timeout"
    end
  end

  test "the owner-only sentence is the published one" do
    assert X.owner_only_sentence() ==
             "Only the owner can pair this Fermix with Fermix Connect or unpair it, " <>
               "from their own app or terminal."

    assert X.owner_only_sentence() in X.sentences()
  end

  test "every sentence is unique" do
    assert X.sentences() == Enum.uniq(X.sentences())
  end

  defp fake(reply, extra \\ []), do: [provider: FakeProvider, reply: reply] ++ extra

  defp session_failures do
    [
      connect_unreachable:
        {"unavailable", "Fermix Connect could not be reached. Try again later."},
      connect_refused: {"refused", "Fermix Connect would not start pairing. Try again later."},
      proof_rejected:
        {"refused", "Fermix Connect did not accept this Fermix's key. Start pairing again."},
      already_paired:
        {"refused", "This Fermix is already paired with Fermix Connect. Unpair it first."},
      unsupported_protocol:
        {"refused", "Fermix Connect does not speak this Fermix's protocol. Update Fermix."},
      key_unavailable:
        {"internal_error", "The instance key could not be created. See the daemon log."},
      record_unwritable:
        {"internal_error", "The pairing could not be saved. See the daemon log."},
      loopback_unavailable:
        {"internal_error",
         "Fermix could not open a local port for the browser to return to. See the daemon log."}
    ]
  end

  defp every_state do
    [
      awaiting_browser: session(:awaiting_browser),
      approved: session(:approved, ttl_ms: nil, handle: "@sam_at_home"),
      denied: session(:denied, ttl_ms: nil),
      expired: session(:expired, ttl_ms: nil),
      cancelled: session(:cancelled, ttl_ms: nil),
      failed: session(:failed, ttl_ms: nil, failure: %{reason: :proof_rejected})
    ]
  end

  defp session(state, fields \\ []) do
    Map.merge(
      %{
        session_id: @session_id,
        state: state,
        ttl_ms: 540_000,
        origin: @origin,
        handle: nil,
        failure: nil
      },
      Map.new(fields)
    )
  end

  defp status do
    %{
      enabled: true,
      paired: %{
        instance_id: @instance_id,
        handle: "@sam_at_home",
        fingerprint: @fingerprint,
        origin: @origin,
        tenant_generation: 1,
        paired_at: "2026-10-16T05:00:00Z"
      },
      connection: :connected,
      refusal: nil,
      pending: 1,
      running: 1,
      last_failure: %{at: "2026-10-16T04:58:12Z", reason: :connection_lost},
      pairing: %{session_id: @session_id, state: :approved}
    }
  end

  defp failed_start(code, sentence) do
    %{
      "session_id" => nil,
      "state" => "failed",
      "ttl_ms" => nil,
      "origin" => @origin,
      "handle" => nil,
      "failure" => %{"code" => code, "sentence" => sentence},
      "confirm_url" => nil
    }
  end
end
