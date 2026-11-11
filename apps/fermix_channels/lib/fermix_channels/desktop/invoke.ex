defmodule FermixChannels.Desktop.Invoke do
  @moduledoc """
  What this computer does when its server asks it to (M97 §6.2): the
  device-only supervisor that takes each `invoke_*` event the relay hands
  it (`handle/4`), admits it, runs it through the same local code a primary
  runs, records it in this computer's journal and answers.

  `:one_for_all` over the runs' `Task.Supervisor` and
  `Desktop.Invoke.Admission`, under `Desktop.DeviceSupervisor` as a
  sibling of the dial subtree, started while this home is linked: a relay
  or dial helper that restarts takes no running invocation with it, so a
  command survives a relay switch (§5.2). If Admission crashes, its runs end
  with it and are journaled `unknown` (`interrupted`) when it starts again;
  what only waited, never journaled, leaves no record, and the results it
  held are lost.

  `capabilities/0` is the one map of what this computer can be asked, one
  line per capability (`FermixCore.Computers.Capability`).

  Every option is explicit, and none is read from application environment
  on the way, so two engines run in one test VM: `:home`, `:switches`
  (0-arity, this computer's switches, `FermixCore.Computers.Switches`),
  `:sandbox` (0-arity, this computer's sandbox config,
  `FermixCore.Sandbox.Config`, read at each request: the files and shell
  capabilities run under it), `:capabilities`, `:clock` (0-arity wall clock)
  and `:relay` (the relay's name), with `:name` and Admission's own seams.
  """

  use Supervisor

  require Logger

  alias FermixChannels.Desktop.Invoke.Admission
  alias FermixCore.Computers.Switches

  @capabilities %{
    "system" => FermixCore.Computers.Capabilities.System,
    "files" => FermixCore.Computers.Capabilities.Files,
    "shell" => FermixCore.Computers.Capabilities.Shell
  }
  @required [:home, :switches, :sandbox, :capabilities, :clock, :relay]

  @doc "What this computer can be asked, by the wire's capability name."
  @spec capabilities() :: %{String.t() => module()}
  def capabilities, do: @capabilities

  @doc """
  This computer's switches as `home`'s `machine.toml` holds them, read at
  each call: the `:switches` a running engine starts with. A file that
  cannot be read is logged and switches everything off.
  """
  @spec switches_in(Path.t()) :: (-> Switches.t())
  def switches_in(home) when is_binary(home) and home != "" do
    fn ->
      case Switches.read(home) do
        {:ok, switches} ->
          switches

        {:error, reason} ->
          Logger.error("this computer's switches could not be read: #{inspect(reason)}")
          [enabled: false]
      end
    end
  end

  @doc "The registered name of the Admission under the supervisor named `name`."
  @spec admission(atom()) :: atom()
  def admission(__MODULE__), do: Switches.invoke_listener()
  def admission(name) when is_atom(name), do: :"#{name}.Admission"

  @doc "The registered name of the runs' supervisor under the supervisor named `name`."
  @spec runs(atom()) :: atom()
  def runs(name) when is_atom(name), do: :"#{name}.Runs"

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    for key <- @required, not Keyword.has_key?(opts, key) do
      raise ArgumentError, "Desktop.Invoke needs #{inspect(key)}"
    end

    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Hands Admission (`server`, a name or pid) one event of the family as the
  relay put it together: its type, its header fields and its payload or raw
  tail. It never waits.
  """
  @spec handle(GenServer.server(), String.t(), map(), binary()) :: :ok
  def handle(server, type, fields, payload)
      when is_binary(type) and is_map(fields) and is_binary(payload),
      do: Admission.handle(server, type, fields, payload)

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    runs = runs(name)

    children = [
      {Task.Supervisor, name: runs},
      {Admission,
       opts |> Keyword.delete(:name) |> Keyword.merge(name: admission(name), runs: runs)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
