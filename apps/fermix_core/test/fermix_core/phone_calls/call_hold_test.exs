defmodule FermixCore.PhoneCalls.CallHoldTest do
  @moduledoc """
  What a phone call in progress holds (M94 §12): the credentials it reads,
  which secrets, while what, and what it does with a ledger it cannot read;
  and the owner's restart, by the same test of "in progress". Every case has a
  ledger of its own; every name, number and id is invented.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Memory.Repo
  alias FermixCore.PhoneCalls.Brief
  alias FermixCore.PhoneCalls.CallHold
  alias FermixCore.PhoneCalls.Ledger

  @t0 ~U[2031-03-04 15:00:00.000000Z]
  @caller "+14155550142"

  # A ledger whose every read fails, as a corrupt store answers.
  defmodule BrokenRepo do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call({:phone_calls, _request}, _from, state),
      do: {:reply, {:error, :corrupt_store}, state}
  end

  setup do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-credential-hold-#{unique}.db")
    repo = :"credential_hold_repo_#{unique}"
    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path}, id: repo)

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    %{repo: repo, unique: unique}
  end

  test "holds the OpenAI key and the trunk password, and nothing else" do
    assert Enum.sort(CallHold.keys()) == [:openai_api_key, :phone_calls_sip_password]
  end

  test "with no call nothing is held", ctx do
    assert CallHold.check_credentials([:openai_api_key, :phone_calls_sip_password],
             repo: ctx.repo
           ) ==
             :ok
  end

  test "a call in progress holds each of the two, with its own sentence", ctx do
    admit!(ctx, "main-hold-1") |> claim!(ctx)

    assert {:error, {:credential_held, :openai_api_key, key_sentence}} =
             CallHold.check_credentials([:openai_api_key], repo: ctx.repo)

    assert key_sentence =~ "A phone call is in progress and uses this key."

    assert {:error, {:credential_held, :phone_calls_sip_password, password_sentence}} =
             CallHold.check_credentials([:phone_calls_sip_password], repo: ctx.repo)

    assert password_sentence =~ "uses this password"

    # A call admitted and not yet dialed reads both at its dispatch too.
    assert {:error, {:credential_held, :openai_api_key, _}} =
             CallHold.check_credentials([:telegram_bot_token, :openai_api_key], repo: ctx.repo)
  end

  test "the SpaceXAI key and unrelated secrets are never held", ctx do
    admit!(ctx, "main-hold-2")

    for key <- [:xai_api_key, :telegram_bot_token, :transcription_openai_api_key] do
      assert CallHold.check_credentials([key], repo: ctx.repo) == :ok, "#{key} was held"
    end
  end

  test "a call that ended, or one only unresolved, holds nothing", ctx do
    ended = admit!(ctx, "main-hold-3")
    claim!(ended, ctx)
    {:ok, _row} = Ledger.terminalize(ended, "ended", %{ended_at: @t0}, server: ctx.repo)
    assert CallHold.check_credentials([:openai_api_key], repo: ctx.repo) == :ok

    lost = admit!(ctx, "main-hold-4", DateTime.add(@t0, 60, :second))
    claim!(lost, ctx)
    {:ok, _row} = Ledger.terminalize(lost, "dispatch_unknown", %{ended_at: @t0}, server: ctx.repo)

    # It still holds the call slot, but nothing of Fermix reads the key for it.
    assert {:ok, [%{id: ^lost}]} = Ledger.unresolved(@t0, server: ctx.repo)
    assert CallHold.check_credentials([:phone_calls_sip_password], repo: ctx.repo) == :ok
  end

  test "with durable memory off no call can run, so nothing is held", ctx do
    repo = :"credential_hold_off_#{ctx.unique}"
    off_path = Path.join(System.tmp_dir!(), "fermix-credential-hold-off-#{ctx.unique}.db")
    start_supervised!({Repo, name: repo, enabled: false, database_path: off_path}, id: repo)

    assert CallHold.check_credentials([:openai_api_key], repo: repo) == :ok
  end

  test "a process whose ledger does not run holds nothing", ctx do
    assert CallHold.check_credentials([:openai_api_key], repo: :"no_ledger_#{ctx.unique}") == :ok
  end

  test "a ledger it cannot read holds the key, since a call may be reading it", ctx do
    repo = :"credential_hold_broken_#{ctx.unique}"
    start_supervised!({BrokenRepo, repo})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:credential_held, :openai_api_key, sentence}} =
                 CallHold.check_credentials([:openai_api_key], repo: repo)

        assert sentence =~ "could not tell whether a phone call is in progress"
      end)

    assert log =~ "corrupt_store"
  end

  # The restart is refused only while a call's worker runs; a row left not
  # ended, or a ledger that cannot be read, are what a restart clears.
  describe "the owner's restart" do
    setup ctx do
      registry = :"restart_hold_registry_#{ctx.unique}"
      start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
      %{registry: registry}
    end

    defp live_worker!(registry, call_id) do
      worker = {Agent, fn -> {:ok, _owner} = Registry.register(registry, call_id, nil) end}
      start_supervised!(worker, id: {:worker, call_id})
    end

    test "is refused while a call's worker runs, in a sentence saying how to go on", ctx do
      id = admit!(ctx, "main-hold-5") |> claim!(ctx)
      live_worker!(ctx.registry, id)

      assert CallHold.check_restart(repo: ctx.repo, registry: ctx.registry) ==
               {:error,
                {:restart_held,
                 "A phone call is in progress, and restarting Fermix now would hang it up " <>
                   "without its outcome. Ask Fermix to stop the call, or let it end, then " <>
                   "restart."}}
    end

    test "runs with no worker, even beside a row left not ended", ctx do
      assert CallHold.check_restart(repo: ctx.repo, registry: ctx.registry) == :ok

      admit!(ctx, "main-hold-6") |> claim!(ctx)
      assert {:ok, true} = CallHold.call_in_progress(repo: ctx.repo)
      assert CallHold.check_restart(repo: ctx.repo, registry: ctx.registry) == :ok
    end

    test "runs when the ledger cannot be read: the engine's stop hangs up a live call first",
         ctx do
      repo = :"restart_hold_broken_#{ctx.unique}"
      start_supervised!({BrokenRepo, repo})

      assert CallHold.check_restart(repo: repo, registry: ctx.registry) == :ok
    end

    test "runs where no call registry runs, since no call does", ctx do
      assert CallHold.check_restart(registry: :"no_registry_#{ctx.unique}") == :ok
      refute CallHold.live_call?(registry: :"no_registry_#{ctx.unique}")
    end

    test "the credentials stay held for a row not ended, worker or not", ctx do
      admit!(ctx, "main-hold-7") |> claim!(ctx)

      assert {:error, {:credential_held, :openai_api_key, _sentence}} =
               CallHold.check_credentials([:openai_api_key], repo: ctx.repo)
    end
  end

  test "every sentence is one" do
    for sentence <- CallHold.sentences() do
      assert sentence =~ ~r/^[A-Z].* .*\.$/
    end
  end

  defp admit!(ctx, request_id, at \\ @t0) do
    {:ok, brief} =
      Brief.new(
        %{
          "destination" => "+12125550101",
          "destination_kind" => "business",
          "number_source" => "The bistro's own website.",
          "contact_name" => "Calloway Bistro",
          "timezone" => "America/New_York",
          "goal" => "Ask for a table for two on Saturday at 19:30.",
          "completion_criteria" => ["The host confirms a table for two at 19:30."]
        },
        caller_number: @caller,
        now: @t0
      )

    attrs = %{
      request_id: request_id,
      owner_id: "default",
      authorization: "direct",
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: "telegram",
      destination: "40017",
      mandate: Brief.to_map(brief),
      mandate_hash: Brief.hash(brief),
      model: "gpt-live-1",
      voice: "marin",
      prompt_version: "phone-test-1",
      carrier_profile: "telnyx_credential_v1"
    }

    {:ok, {:admitted, row}} = Ledger.admit(attrs, at, server: ctx.repo)
    row.id
  end

  defp claim!(id, ctx) do
    {:ok, _row} = Ledger.claim_dispatch(id, @t0, server: ctx.repo)
    id
  end
end
