defmodule FermixCore.Setup.BootReport do
  @moduledoc """
  Runtime-owned view of the current setup/readiness report.
  """

  use GenServer

  alias FermixCore.Setup.Wizard

  @type state :: Wizard.report()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec current() :: state()
  def current, do: GenServer.call(__MODULE__, :current)

  @spec refresh() :: state()
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @spec refresh_if_started() :: state() | nil
  def refresh_if_started, do: refresh_if_started([])

  @spec refresh_if_started([Wizard.seeding_result()]) :: state() | nil
  def refresh_if_started(seeding_results) when is_list(seeding_results) do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, {:refresh, seeding_results})
    end
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(:ok), do: {:ok, Wizard.report()}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call(:refresh, _from, _state) do
    state = Wizard.report()
    {:reply, state, state}
  end

  def handle_call({:refresh, seeding_results}, _from, _state) do
    state = Wizard.report(seeding_results)
    {:reply, state, state}
  end
end
