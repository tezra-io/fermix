defmodule FermixCore.Cues do
  @moduledoc """
  Cues and watchers (M60): push input that wakes an agent.

  This module holds the subsystem's gates, its two wake-ups and its id helper.
  Accepting input is `FermixCore.Cues.Ingest`; the rows live in `memory.db`
  behind `FermixCore.Memory.Repo.cues_call/3`.

  ## Gates

  `enabled?/0` is the `[fermix_core.cues] enabled` flag (default off) with
  memory on, since every cue is a row in `memory.db`.

  `enabled?/0` is for decisions taken at boot (whether the tree starts, which
  tools are seeded). Everything that asks at runtime (a tool's advertisement,
  the scheduler's admission) asks `running?/0`, whether the cue tree is alive:
  the tree starts only at boot, so the switch flipped live changes nothing
  until a restart, and no runtime check sees half of the feature.
  """

  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Filters
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Config, as: MemoryConfig

  @doc """
  Whether the cue subsystem is switched on: `enabled`, and memory on. A boot decision (the tree, the seeded tools); runtime asks `running?/0`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Config.enabled?() == true and MemoryConfig.enabled?()
  end

  @doc """
  Whether the cue tree is alive (`FermixCore.Cues.Supervisor` is registered).
  The runtime gate: see the moduledoc.
  """
  @spec running?() :: boolean()
  def running?, do: Process.whereis(FermixCore.Cues.Supervisor) != nil

  @doc """
  Wakes `FermixCore.Cues.Filters` after deliveries for `llm` watchers commit.
  A no-op while the dispatcher is not running; a lost wake-up is found by its
  60 s sweep (design §7.1).
  """
  @spec wake_filters() :: :ok
  def wake_filters do
    if Process.whereis(Filters), do: Filters.wake()
    :ok
  end

  @doc """
  Wakes `FermixCore.Jobs.Scheduler` after passed deliveries commit, through
  its `cue_wake/1` cast. A no-op while the scheduler is not running; a lost
  wake-up is found by its reconcile tick.
  """
  @spec wake_scheduler() :: :ok
  def wake_scheduler do
    if Process.whereis(Scheduler), do: Scheduler.cue_wake(Scheduler)
    :ok
  end

  @doc """
  A prefixed random id for the cue tables with text keys: `cwt_` watcher,
  `cwi_` instruction, `cwe_` example, `cgp_` gap, `cfc_` filter call, `cmc_`
  mandate call, `cpr_` proposal.
  """
  @spec id(String.t()) :: String.t()
  def id(prefix) when is_binary(prefix) and byte_size(prefix) in 2..4 do
    if String.match?(prefix, ~r/^[a-z]+$/) do
      prefix <> "_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    else
      raise ArgumentError, "a cue id prefix is 2 to 4 lowercase letters, got: #{inspect(prefix)}"
    end
  end
end
