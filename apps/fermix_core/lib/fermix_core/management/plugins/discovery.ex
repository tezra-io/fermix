defmodule FermixCore.Management.Plugins.Discovery do
  @moduledoc """
  The last workspace discovery per plugin, so `plugins.list` can republish it
  (M34 native setup §5.6).

  A job result is flat scalars only, so the workspaces a discovery found cannot
  ride back on the job that found them. They are held here instead and appear on
  the plugin row, which is where the choosing surface reads them: the sheet
  starts a discovery, waits for the job to end, re-reads the catalogue, and
  renders the row's own list.

  Boot-bound and deliberately unpersisted. A workspace id names the operator's
  own data, and what this answers is "what the last discovery on this daemon
  found" — a restart is exactly what should clear it. The next discovery for a
  plugin replaces its list rather than adding to it.

  Reads answer `[]` with no server running. A tree-less verb has run no
  discovery, so it has nothing to report; that is two declared configurations of
  one read, not a fallback.
  """

  use GenServer

  # The wire publishes at most 100 workspaces on a row, and a machine that has
  # discovered more than 20 remote plugins in one boot is discovering in a loop.
  @max_workspaces 100
  @max_plugins 20

  @type workspace :: %{id: String.t(), label: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The most workspaces one row publishes."
  @spec max_workspaces() :: pos_integer()
  def max_workspaces, do: @max_workspaces

  @doc """
  Records what one discovery found, replacing that plugin's previous list.

  Answers `:ok` with no server running: the discovery itself already happened,
  and only the record is skipped.
  """
  @spec record(String.t(), [workspace()], keyword()) :: :ok
  def record(name, workspaces, opts \\ [])
      when is_binary(name) and is_list(workspaces) and is_list(opts) do
    call(opts, {:record, name, Enum.take(workspaces, @max_workspaces)}, :ok)
  end

  @doc "What the last discovery for `name` found, newest wins; `[]` when none has run."
  @spec fetch(String.t(), keyword()) :: [workspace()]
  def fetch(name, opts \\ []) when is_binary(name) and is_list(opts) do
    call(opts, {:fetch, name}, [])
  end

  @doc "Every plugin with a retained discovery, keyed by name."
  @spec all(keyword()) :: %{String.t() => [workspace()]}
  def all(opts \\ []) when is_list(opts), do: call(opts, :all, %{})

  @impl true
  def init(_opts), do: {:ok, %{found: %{}, order: []}}

  @impl true
  def handle_call({:record, name, workspaces}, _from, state) do
    order = Enum.take([name | List.delete(state.order, name)], @max_plugins)
    found = state.found |> Map.put(name, workspaces) |> Map.take(order)

    {:reply, :ok, %{found: found, order: order}}
  end

  def handle_call({:fetch, name}, _from, state) do
    {:reply, Map.get(state.found, name, []), state}
  end

  def handle_call(:all, _from, state), do: {:reply, state.found, state}

  defp call(opts, message, absent_answer) do
    case Process.whereis(Keyword.get(opts, :discovery, __MODULE__)) do
      nil -> absent_answer
      pid -> GenServer.call(pid, message)
    end
  catch
    # Only an absent process reads as the absent answer. A timeout or a crashed
    # server is a wedged daemon, and mapping it to the default would draw a
    # healthy surface over it.
    :exit, {:noproc, _call} -> absent_answer
  end
end
