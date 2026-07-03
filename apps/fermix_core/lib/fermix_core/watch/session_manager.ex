defmodule FermixCore.Watch.SessionManager do
  @moduledoc """
  Finds or lazily starts the one `Watch.Session` per conversation, and tears it
  down on demand. Keyed by `conversation_key`.

  `ensure/2` **fails closed for an unattended origin** (§7.6 — a watch delivers
  live updates to a present human; a detached/background "watch" is a
  `schedule_job`, not this) and, on start, builds the session's observe/deliver
  effects via `Watch.Runtime` (overridable in tests). Mirrors
  `ComputerUse.SessionManager` — same registry + DynamicSupervisor +
  `terminate_child` teardown (a dead-pid race can't crash the caller and a
  `:temporary` child stays down), and `abort/1` is a clean no-op when the registry
  isn't running.
  """

  alias FermixCore.Watch.Runtime
  alias FermixCore.Watch.Session
  alias FermixCore.Watch.Supervisor, as: WatchSupervisor

  # A watch requires an attended origin (a present human to receive its updates).
  # Mirrors `ComputerUse.Safety.@attended_origins`; the two are independent
  # capabilities that happen to share the "attended" concept.
  @attended_origins [:interactive, :voice]

  @doc """
  Find or start the watch for `context`'s conversation. `opts` must carry
  `:task` (the watch instruction). Returns the pid, `{:error, {:watch_refused,
  origin}}` for an unattended origin, or a build/start error.
  """
  @spec ensure(map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure(context, opts \\ []) when is_map(context) do
    key = conversation_key(context)

    case Registry.lookup(WatchSupervisor.registry(), key) do
      [{pid, _}] -> {:ok, pid}
      [] -> start_session(key, context, opts)
    end
  end

  @doc "The running watch for this conversation, if any."
  @spec lookup(map()) :: {:ok, pid()} | :error
  def lookup(context) when is_map(context) do
    case Registry.lookup(WatchSupervisor.registry(), conversation_key(context)) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Tear down the watch for `context`'s conversation, if one is running. Idempotent
  — a no-op when none exists, the context carries no conversation key, or the
  registry isn't running.
  """
  @spec abort(map()) :: :ok
  def abort(context) when is_map(context) do
    with true <- registry_running?(),
         true <- Map.has_key?(context, :conversation_key),
         {:ok, pid} <- lookup(context) do
      DynamicSupervisor.terminate_child(WatchSupervisor.session_supervisor(), pid)
      :ok
    else
      _ -> :ok
    end
  end

  defp start_session(key, context, opts) do
    origin = origin(context)
    task = Keyword.fetch!(opts, :task)

    with :ok <- precheck_attended(origin),
         {:ok, decide, deliver} <- effects(context, task, opts) do
      child = {Session, session_opts(key, context, origin, task, decide, deliver, opts)}

      case DynamicSupervisor.start_child(WatchSupervisor.session_supervisor(), child) do
        {:ok, pid} -> {:ok, pid}
        # A concurrent request started it first — reuse the winner.
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Tests inject `:decide`/`:deliver` directly; production builds them from the
  # runtime (one turn-state checkout + delivery resolution, up front).
  defp effects(context, task, opts) do
    case {Keyword.get(opts, :decide), Keyword.get(opts, :deliver)} do
      {decide, deliver} when is_function(decide, 1) and is_function(deliver, 1) ->
        {:ok, decide, deliver}

      _ ->
        Keyword.get(opts, :runtime, Runtime).build(context, task)
    end
  end

  defp session_opts(key, context, origin, task, decide, deliver, opts) do
    [
      name: {:via, Registry, {WatchSupervisor.registry(), key}},
      conversation_key: key,
      task: task,
      decide: decide,
      deliver: deliver,
      origin: origin,
      parent_session: Map.get(context, :session_id)
    ] ++ Keyword.take(opts, [:max_duration_ms, :max_cycles, :cooldown_ms, :task_supervisor])
  end

  defp precheck_attended(origin) do
    if origin in @attended_origins, do: :ok, else: {:error, {:watch_refused, origin}}
  end

  # The turn's attended-origin signal (`:interactive`/`:voice`/`:unattended`),
  # the same key computer-use reads; defaults to unattended so an unforeseen
  # path fails closed.
  defp origin(context), do: Map.get(context, :computer_use_origin, :unattended)

  defp registry_running?, do: is_pid(Process.whereis(WatchSupervisor.registry()))

  defp conversation_key(context), do: Map.fetch!(context, :conversation_key)
end
