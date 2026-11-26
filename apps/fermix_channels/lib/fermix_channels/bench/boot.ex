defmodule FermixChannels.Bench.Boot do
  @moduledoc """
  What a benchmark run needs that a booted engine would have given it, for the
  VM `mix fermix.bench` and `mix fermix.bench.soak` run in: one that reads the
  configuration and starts no application (M107).

    * `with_home/1` runs the benchmark in a home of its own, made before the
      configuration is read and removed after the run. A run reads its home
      (the settings and machine file `app.config` hydrates and may migrate,
      the prompt files each turn's context is composed from, the moved marker
      and the primary epoch) and writes nothing there, so in someone's home it
      would measure that home and could migrate it. The runner keeps every
      other piece of state the same way: it makes its own and removes it.
    * `with_engine/1` records the boot facts a turn reads, in
      `FermixCore.Application.start/2`'s order (the boot profile, the engine
      role, the host facts), and starts what a turn and a channel send call by
      name: the `:telemetry` and `:req` applications (a channel scenario's
      sends go through Req, answered by `Req.Test` stubs), a disabled
      `Memory.Repo` (prompt composition records revisions against it, and
      disabled every call is a no-op that never opens SQLite), `ReplyBlocks`
      and `Gateway.Idempotency`.

  Each undoes what it did, in reverse, however the run ends. The suite's VM
  booted the engine, so its tree holds all of this already, and the suite
  names a home of its own: its tests call the runner without either.
  """

  alias FermixChannels.Gateway.Idempotency
  alias FermixCore.BootProfile
  alias FermixCore.Home.Role
  alias FermixCore.HostFacts
  alias FermixCore.Memory.Repo
  alias FermixCore.ReplyBlocks
  alias FermixCore.Setup.ConfigStore

  require Logger

  @doc """
  Runs `fun` with `FERMIX_HOME` naming a new, empty home under the system's
  temporary directory, then restores the caller's `FERMIX_HOME` and removes
  the home. Call it before the configuration is read (`app.config`), which is
  the first thing to read the home.
  """
  @spec with_home((-> result)) :: result when result: term()
  def with_home(fun) when is_function(fun, 0) do
    home = Path.join(System.tmp_dir!(), "fermix-bench-home-#{random_suffix()}")
    File.mkdir!(home)
    caller_home = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    try do
      fun.()
    after
      restore_home_variable(caller_home)
      remove_home(home)
    end
  end

  @doc """
  Runs `fun` with the boot facts recorded and the processes a benchmark turn
  calls by name started, then stops and forgets them. Only for a VM that
  booted no engine: a booted one already has every one of them.
  """
  @spec with_engine((-> result)) :: result when result: term()
  def with_engine(fun) when is_function(fun, 0), do: within(engine_steps(), fun)

  # A Mix task runs from source, so its profile is `:source`, the one
  # `BootProfile.select/2` gives any run that is neither the app's engine nor
  # a packaged binary. The role is read as the engine's boot reads it.
  defp engine_steps do
    [
      {fn -> BootProfile.remember(:source) end, fn :ok -> BootProfile.forget() end},
      {&remember_role/0, fn :ok -> Role.forget() end},
      {&HostFacts.remember/0, fn :ok -> HostFacts.forget() end},
      {fn -> start_applications!([:telemetry, :req]) end, &stop_applications/1},
      {fn -> start_process!(Repo, enabled: false) end, &stop_process/1},
      {fn -> start_process!(ReplyBlocks, []) end, &stop_process/1},
      {fn -> start_process!(Idempotency, []) end, &stop_process/1}
    ]
  end

  # Each step starts one thing and hands its stop what it started. A step
  # starts only once every step before it has, and its stop runs however the
  # steps after it and the run end.
  defp within([], fun), do: fun.()

  defp within([{start, stop} | rest], fun) do
    started = start.()

    try do
      within(rest, fun)
    after
      stop.(started)
    end
  end

  defp remember_role,
    do: Role.remember!(ConfigStore.fermix_home(), Application.get_env(:fermix_core, :engine, []))

  defp start_applications!(apps) do
    {:ok, started} = Application.ensure_all_started(apps)
    started
  end

  defp stop_applications(started) do
    started |> Enum.reverse() |> Enum.each(fn app -> :ok = Application.stop(app) end)
  end

  defp start_process!(module, opts) do
    {:ok, pid} = module.start_link(opts)
    pid
  end

  defp stop_process(pid), do: :ok = GenServer.stop(pid)

  # Random, never a counter: every VM's counters start alike, so a counter
  # names the same home in every run. A run killed before it removed its home
  # would then stop every run after it, and two runs at once would take each
  # other's.
  defp random_suffix, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  defp restore_home_variable(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home_variable(home), do: System.put_env("FERMIX_HOME", home)

  # The home is removed as the empty directory it was made as, never as a
  # tree. A run writes nothing there, so anything left is named in the log
  # (after the run's own outcome, which this must not replace) and kept.
  defp remove_home(home) do
    case File.rmdir(home) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "benchmark home not removed: #{home}: #{inspect(reason)}; it holds #{inspect(File.ls(home))}"
        )
    end
  end
end
