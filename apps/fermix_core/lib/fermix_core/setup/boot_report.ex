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

  @impl true
  def init(:ok), do: {:ok, Wizard.report()}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call(:refresh, _from, _state) do
    state = Wizard.report()
    {:reply, state, state}
  end
end
