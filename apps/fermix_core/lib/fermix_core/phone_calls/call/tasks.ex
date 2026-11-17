defmodule FermixCore.PhoneCalls.Call.Tasks do
  @moduledoc """
  The linked tasks a phone call's worker owns, so it never waits in a
  callback: at most one of each named kind (`:create`, `:hangup`,
  `:extract`), and the stops of backend turns (`Delegate.cancel/2`), any
  number, never waited on.

  Every function runs in the worker, the tasks' owner. A task's result or
  its `:DOWN` arrives as a message; `owner/2` says whose it is, and the
  owner drops it, its monitor flushed. A named task past its watchdog is
  shut down at once, and a result that arrived as the watchdog fired still
  counts (`expire/2`). The stops still running when the call reports end
  with it (`shutdown_stops/1`).
  """

  defstruct named: %{}, stops: %{}

  @type kind :: :create | :hangup | :extract
  @type t :: %__MODULE__{
          named: %{optional(kind()) => Task.t()},
          stops: %{reference() => Task.t()}
        }

  @doc "No task running."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Runs `fun` as the one task of `kind`."
  @spec start(t(), kind(), (-> term())) :: t()
  def start(%__MODULE__{named: named} = tasks, kind, fun)
      when kind in [:create, :hangup, :extract] and not is_map_key(named, kind) and
             is_function(fun, 0),
      do: %{tasks | named: Map.put(named, kind, Task.async(fun))}

  @doc "Runs a backend turn's stop, which is never waited on."
  @spec start_stop(t(), (-> term())) :: t()
  def start_stop(%__MODULE__{} = tasks, fun) when is_function(fun, 0) do
    task = Task.async(fun)
    %{tasks | stops: Map.put(tasks.stops, task.ref, task)}
  end

  @doc "Whose a task message is, by its monitor reference."
  @spec owner(t(), reference()) :: {:named, kind()} | :stop | :none
  def owner(%__MODULE__{} = tasks, ref) do
    cond do
      kind = Enum.find_value(tasks.named, fn {kind, task} -> task.ref == ref && kind end) ->
        {:named, kind}

      is_map_key(tasks.stops, ref) ->
        :stop

      true ->
        :none
    end
  end

  @doc "Drops the task whose result or `:DOWN` arrived, flushing its monitor."
  @spec drop(t(), reference()) :: t()
  def drop(%__MODULE__{} = tasks, ref) do
    Process.demonitor(ref, [:flush])

    %{
      tasks
      | named: Map.reject(tasks.named, fn {_kind, task} -> task.ref == ref end),
        stops: Map.delete(tasks.stops, ref)
    }
  end

  @doc """
  Shuts down `kind`'s task past its watchdog: `{:result, result, tasks}`
  when its result arrived meanwhile, `{:killed, tasks}` when it did not, and
  `:none` when no such task runs.
  """
  @spec expire(t(), kind()) :: {:result, term(), t()} | {:killed, t()} | :none
  def expire(%__MODULE__{} = tasks, kind) do
    case Map.fetch(tasks.named, kind) do
      {:ok, task} -> expired(tasks, task, Task.shutdown(task, :brutal_kill))
      :error -> :none
    end
  end

  defp expired(tasks, task, {:ok, result}), do: {:result, result, drop(tasks, task.ref)}
  defp expired(tasks, task, _killed), do: {:killed, drop(tasks, task.ref)}

  @doc "Stops `kind`'s task, if one runs, without its result."
  @spec shutdown(t(), kind()) :: t()
  def shutdown(%__MODULE__{} = tasks, kind) do
    case Map.pop(tasks.named, kind) do
      {nil, _named} -> tasks
      {task, named} -> shut(%{tasks | named: named}, task)
    end
  end

  @doc "Stops every backend turn's stop still running."
  @spec shutdown_stops(t()) :: t()
  def shutdown_stops(%__MODULE__{} = tasks) do
    Enum.each(tasks.stops, fn {_ref, task} -> Task.shutdown(task, :brutal_kill) end)
    %{tasks | stops: %{}}
  end

  @doc "Whether `kind`'s task runs."
  @spec running?(t(), kind()) :: boolean()
  def running?(%__MODULE__{named: named}, kind), do: is_map_key(named, kind)

  defp shut(tasks, task) do
    _result = Task.shutdown(task, :brutal_kill)
    tasks
  end
end
