defmodule FermixCore.Realtime.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for local Realtime voice sessions.
  """

  use DynamicSupervisor

  alias FermixCore.Realtime.SessionServer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_session(GenServer.server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(server \\ __MODULE__, opts) when is_list(opts) do
    DynamicSupervisor.start_child(server, {FermixCore.Realtime.SessionServer, opts})
  end

  @spec active_sessions(GenServer.server()) :: non_neg_integer()
  def active_sessions(server \\ __MODULE__) do
    server
    |> DynamicSupervisor.count_children()
    |> Map.get(:active, 0)
  rescue
    _error -> 0
  end

  @spec reload_sessions(GenServer.server()) ::
          {:ok, %{active: non_neg_integer(), reloaded: non_neg_integer(), failed: [term()]}}
          | {:error, term()}
  def reload_sessions(server \\ __MODULE__) do
    server
    |> DynamicSupervisor.which_children()
    |> Enum.map(&reload_child/1)
    |> summarize_reloads()
  catch
    :exit, reason -> {:error, reason}
  end

  defp reload_child({_id, pid, :worker, _modules}) when is_pid(pid) do
    case SessionServer.reload_runtime(pid) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reload_child(_child), do: {:error, :invalid_realtime_session_child}

  defp summarize_reloads(results) do
    failures =
      results
      |> Enum.filter(&match?({:error, _reason}, &1))
      |> Enum.map(fn {:error, reason} -> reason end)

    summary = %{
      active: length(results),
      reloaded: length(results) - length(failures),
      failed: failures
    }

    if failures == [] do
      {:ok, summary}
    else
      {:error, {:realtime_reload_failed, summary}}
    end
  end
end
