defmodule FermixCore.Management.AlwaysOnLogTest do
  # Always On setup §3.4, §6: an act logs the step and who asked, and nothing
  # of its input; a crash of the serializer reports its last message, whose
  # input withholds the token and the recovery passphrase. Synchronous: it
  # raises the logger's level for the suite's one VM and asserts absences in
  # what was logged.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Management.AlwaysOn
  alias FermixCore.Management.AlwaysOn.Input
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeSummary
  alias FermixTestSupport.FakeCloudProvider
  alias FermixTestSupport.SafeRm

  @at ~U[2031-05-04 12:00:00Z]
  @passphrase "invented-lighthouse-meridian"
  @token "invented-wrong-token-00000"

  setup ctx do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    home = SafeRm.make_tmp_dir!("always_on_log")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    {:ok, held} = Candidates.add(home, candidate_attrs(), @at)
    serializer = :"always_on_log_#{:erlang.phash2(ctx.test)}"
    start_supervised!({AlwaysOn, name: serializer})
    {:ok, kept} = Recipient.from_passphrase("invented-orchard-meridian-77")

    window = %{
      state: :used,
      expires_at: ~U[2031-05-04 12:30:00Z],
      kind: :manual,
      candidate_id: held.candidate_id,
      awake_ms: 0
    }

    opts = [
      home: home,
      engine_role: %{role: :primary, primary: nil},
      profile: "general",
      now: @at,
      host_os: :linux,
      config: [recipient: Recipient.encode(kept)],
      scheduler: nil,
      disk_usage: fn _home -> {:ok, %{used: 0.42, nearly_full: false}} end,
      link_status: fn -> %{primary: nil, desktops: [], enrollment: window} end,
      providers: [FakeCloudProvider],
      provider_opts: [world: FakeCloudProvider.start!(), now: fn -> @at end],
      free_bytes: fn _dir -> {:ok, 1_099_511_627_776} end,
      version: "9.9.9",
      host: "linux-x86_64",
      restarts_itself: true,
      restart: fn -> :ok end,
      save_recipient: fn _recipient -> {:ok, %{}} end,
      serializer: serializer
    ]

    # A home with nothing in it, whose screen asks for the token.
    fresh = SafeRm.make_tmp_dir!("always_on_log_token")
    on_exit(fn -> SafeRm.rm_rf!(fresh) end)
    :ok = Epoch.write(fresh, 4)

    token_opts =
      Keyword.merge(opts,
        home: fresh,
        link_status: fn -> %{primary: nil, desktops: [], enrollment: nil} end
      )

    %{opts: opts, token_opts: token_opts}
  end

  test "an act names the step and never the token or the recovery passphrase", ctx do
    log =
      capture_log([level: :debug], fn ->
        assert {:error, :invalid_params, %{"field" => "recovery_passphrase"}} =
                 press(ctx.opts, "move_now", %Input{recovery_passphrase: @passphrase})

        assert {:error, :invalid_params, %{"field" => "token"}} =
                 press(ctx.token_opts, "paste_token", %Input{token: @token})
      end)

    assert log =~ "move_now"
    assert log =~ "paste_token"
    refute log =~ @passphrase
    refute log =~ @token
  end

  test "a step that crashes the serializer leaves neither secret in its report", ctx do
    Process.flag(:trap_exit, true)

    opts =
      Keyword.merge(ctx.opts, config: [], restart: fn -> raise "invented restart failure" end)

    input = %Input{token: @token, recovery_passphrase: @passphrase}

    log = capture_log([level: :debug], fn -> catch_exit(press(opts, "move_now", input)) end)

    assert log =~ "invented restart failure"
    refute log =~ @passphrase
    refute log =~ @token
  end

  defp press(opts, id, input) do
    summary = opts |> Home.summary_facts() |> HomeSummary.summary()
    %{"key" => key} = Enum.find(HomeSummary.offered(summary), &(&1["id"] == id))
    AlwaysOn.act(%{action: id, key: key, input: input}, opts)
  end

  defp candidate_attrs do
    %{
      name: "fermix-general-a3f9",
      os: "linux",
      arch: "x86_64",
      version: "9.9.9",
      node_id: String.duplicate("b7", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<1>>, 32),
      recipient: :binary.copy(<<2>>, 32),
      snapshots: nil
    }
  end
end
