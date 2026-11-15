defmodule FermixCore.Realtime.CallLease do
  @moduledoc """
  One owner-voice call per home, across every voice engine and every endpoint
  (M91 §04, D22).

  One unique-key `Registry` under `Realtime.Supervisor`, started before
  `SessionSupervisor`. Every engine session (`SessionServer`,
  `LiveSessionServer`, `GrokSessionServer`) acquires the lease from its own
  `init/1`, before anything that can bill, so of two endpoints starting a call
  at once exactly one wins (one `:ets.insert_new/2`) and the other is refused
  before its session exists. The lease belongs to the session process and lasts
  exactly as long as it does: through its settle, so a call still settling
  counts, and no longer, however it ends. A crashed session releases it with no
  code of its own.

  The lease's value names its holder: the endpoint's string form, the engine
  and when the call started, so a refusal says where the call is.
  `CallRegistry` keeps the other meaning, where Channels finds a task-engine
  call's chat context; it is no longer where a call is admitted.
  """

  alias FermixCore.Realtime.Endpoint

  require Logger

  @key :owner_voice_call
  # A holder that ends between a lost acquire and the read of who holds the
  # lease has freed it: take it once more. At the cap the call is refused
  # without a name.
  @max_attempts 2

  @type registry :: atom()

  @typedoc "Who holds the lease: the call's endpoint string, its engine and its start."
  @type holder :: %{endpoint: String.t(), engine: String.t(), started_at: DateTime.t()}

  @typedoc "Why a call was not admitted: another call holds the lease, at `held_by`."
  @type refusal :: {:call_in_progress, String.t() | nil}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    Registry.child_spec(keys: :unique, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Takes the home's one call for the calling process.

  `{:error, {:call_in_progress, held_by}}` while another process holds it,
  `held_by` the holder's endpoint string.
  """
  @spec acquire(registry(), Endpoint.t(), String.t()) :: :ok | {:error, refusal()}
  def acquire(registry, endpoint, engine)
      when is_atom(registry) and is_binary(engine) and engine != "" do
    holder = %{
      endpoint: Endpoint.format(endpoint),
      engine: engine,
      started_at: DateTime.utc_now()
    }

    take(registry, holder, @max_attempts)
  end

  @doc """
  Who holds the lease, or `:none`. `Registry.lookup/2` still answers with an
  owner that has exited until the registry has processed its exit, while
  `Registry.register/3` already treats that owner's key as free, so a dead
  owner is skipped here too.
  """
  @spec holder(registry()) :: {:ok, holder()} | :none
  def holder(registry) when is_atom(registry) do
    case Registry.lookup(registry, @key) do
      [{owner, holder}] -> if Process.alive?(owner), do: {:ok, holder}, else: :none
      [] -> :none
    end
  end

  defp take(registry, holder, attempts_left) do
    case Registry.register(registry, @key, holder) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _owner}} -> refuse(registry, holder, attempts_left - 1)
    end
  end

  defp refuse(registry, holder, attempts_left) do
    case holder(registry) do
      {:ok, held} -> refused(holder, held.endpoint)
      :none when attempts_left > 0 -> take(registry, holder, attempts_left)
      :none -> refused(holder, nil)
    end
  end

  defp refused(holder, held_by) do
    Logger.info(
      "voice: refused a #{holder.endpoint} call on #{holder.engine}: " <>
        "#{held_by || "another endpoint"} holds the call"
    )

    {:error, {:call_in_progress, held_by}}
  end
end
