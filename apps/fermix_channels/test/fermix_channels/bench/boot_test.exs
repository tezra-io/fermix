defmodule FermixChannels.Bench.BootTest do
  @moduledoc """
  What `Bench.Boot` makes for a benchmark run is gone when the run ends, after
  a run that passed and after one that failed.

  Only a VM that booted no engine has anything to make, and the suite's VM
  booted one, so the probe runs in a fresh OS process (`mix run --no-start`),
  the world `mix fermix.bench` runs in. It reports what it saw as one term,
  and every assertion is made here.

  Tagged `:subprocess` (`mix test --exclude subprocess` skips it).
  """

  use ExUnit.Case, async: false

  alias FermixTestSupport.SafeRm

  @moduletag :subprocess
  # A child `mix` boots inside each test. With every core busy that boot alone
  # takes about a minute, so the default 60 s would fail a run that is only
  # slow; this is the bound on a child that hangs.
  @moduletag timeout: 300_000

  @probe ~S"""
  alias FermixChannels.Bench.Boot
  alias FermixChannels.Bench.Runner
  alias FermixCore.Bench.MockProvider

  defmodule Probe.WrongReply do
    def chat(messages, capabilities, opts),
      do: MockProvider.chat(messages, capabilities, wrong(opts))

    def continue(state, results, opts), do: MockProvider.continue(state, results, wrong(opts))
    defdelegate to_provider_tools(capabilities), to: MockProvider
    defdelegate parse_tool_calls(response), to: MockProvider
    defdelegate parse_response(response), to: MockProvider
    defdelegate supports_streaming?(), to: MockProvider
    defp wrong(opts), do: Keyword.put(opts, :bench_response, "not the scenario's reply")
  end

  defmodule Probe do
    def world do
      %{
        boot_profile: Application.fetch_env(:fermix_core, :boot_profile),
        engine_role: FermixCore.Home.Role.booted(),
        host_facts: if(Application.get_env(:fermix_core, :host_facts), do: :ok, else: :error),
        apps: Enum.map(Application.started_applications(), &elem(&1, 0)),
        registered: Process.registered(),
        links: self() |> Process.info(:links) |> elem(1),
        fermix_home: System.get_env("FERMIX_HOME")
      }
    end

    def left_behind(before, now) do
      %{
        boot_profile: now.boot_profile,
        engine_role: now.engine_role,
        host_facts: now.host_facts,
        apps: now.apps -- before.apps,
        registered: now.registered -- before.registered,
        links: length(now.links -- before.links),
        fermix_home_restored: now.fermix_home == before.fermix_home
      }
    end

    def bench(provider) do
      Runner.run(
        scenarios: ["shared_text_minimal"],
        samples: 2,
        warmup: 1,
        output: nil,
        provider: provider
      )
    end

    def failed_run do
      Boot.with_engine(fn -> bench(Probe.WrongReply) end)
      :no_failure
    rescue
      error in RuntimeError -> Exception.message(error)
    end

    def home_of_raising_run do
      Boot.with_home(fn -> raise RuntimeError, System.get_env("FERMIX_HOME") end)
    rescue
      error in RuntimeError -> Exception.message(error)
    end
  end

  before = Probe.world()

  {{:ok, report}, during} =
    Boot.with_engine(fn -> {Probe.bench(MockProvider), Probe.world()} end)

  after_success = Probe.world()
  failure = Probe.failed_run()
  after_failure = Probe.world()

  {home, home_entries} =
    Boot.with_home(fn ->
      home = System.get_env("FERMIX_HOME")
      {home, File.ls(home)}
    end)

  raised_home = Probe.home_of_raising_run()

  result = %{
    before: Probe.left_behind(before, before),
    during: %{
      boot_profile: during.boot_profile,
      engine_role: during.engine_role,
      host_facts: during.host_facts,
      apps: during.apps -- before.apps,
      registered: during.registered -- before.registered
    },
    processed: report.scenarios["shared_text_minimal"].messages_processed,
    after_success: Probe.left_behind(before, after_success),
    failure: failure,
    after_failure: Probe.left_behind(before, after_failure),
    home: %{
      caller: before.fermix_home,
      used: home,
      entries: home_entries,
      exists_after: File.exists?(home),
      restored: System.get_env("FERMIX_HOME") == before.fermix_home
    },
    raised_home: %{
      used: raised_home,
      exists_after: File.exists?(raised_home),
      restored: System.get_env("FERMIX_HOME") == before.fermix_home
    }
  }

  IO.puts("PROBE " <> Base.encode64(:erlang.term_to_binary(result)))
  """

  @nothing_left %{
    boot_profile: :error,
    engine_role: nil,
    host_facts: :error,
    apps: [],
    registered: [],
    links: 0,
    fermix_home_restored: true
  }

  # One probe answers both tests: each subprocess costs a Mix start.
  setup_all do
    root = SafeRm.make_tmp_dir!("fermix-bench-boot")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    home = Path.join(root, "home")
    File.mkdir!(home)
    probe = Path.join(root, "probe.exs")
    File.write!(probe, @probe)
    %{home: home, result: run_probe!(probe, home)}
  end

  test "leaves no fact or process behind after a run, passed or failed", %{result: result} do
    assert result.before == @nothing_left

    assert %{boot_profile: {:ok, :source}, engine_role: %{role: :primary}, host_facts: :ok} =
             result.during

    assert :telemetry in result.during.apps
    assert :req in result.during.apps

    for name <- [
          FermixCore.Memory.Repo,
          FermixCore.ReplyBlocks,
          FermixChannels.Gateway.Idempotency
        ] do
      assert name in result.during.registered
    end

    assert result.processed == 2
    assert result.after_success == @nothing_left

    assert is_binary(result.failure) and result.failure =~ "not the scenario's reply"
    assert result.after_failure == @nothing_left
  end

  test "runs in a home of its own and removes it, passed or failed",
       %{home: home, result: result} do
    assert result.home.caller == home
    refute result.home.used == home
    assert result.home.entries == {:ok, []}
    refute result.home.exists_after
    assert result.home.restored

    refute result.raised_home.used == home
    refute result.raised_home.exists_after
    assert result.raised_home.restored
  end

  # Every VM's counters start alike, so a home named by one was the same name
  # in every run: a run killed before it removed its home stopped every run
  # after it, and two runs at once took each other's (M107).
  test "names each home by random bytes, so no two runs can pick the same one",
       %{result: result} do
    for used <- [result.home.used, result.raised_home.used] do
      assert Path.basename(used) =~ ~r/\Afermix-bench-home-[0-9a-f]{16}\z/
    end

    refute result.home.used == result.raised_home.used
  end

  defp run_probe!(probe, home) do
    {out, status} =
      System.cmd("mix", ["run", "--no-start", "--no-compile", probe],
        cd: umbrella_root(),
        env: [{"MIX_ENV", "test"}, {"FERMIX_HOME", home}],
        stderr_to_stdout: true
      )

    if status != 0, do: flunk("the probe exited #{status}:\n#{out}")

    [encoded] =
      for "PROBE " <> encoded <- String.split(out, "\n"), do: encoded

    encoded |> Base.decode64!() |> :erlang.binary_to_term()
  end

  # `mix test` runs with cwd set to the app directory; `mix run` reads the
  # umbrella's configuration from its root.
  defp umbrella_root do
    Mix.Project.build_path() |> Path.dirname() |> Path.dirname()
  end
end
