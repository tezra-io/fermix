defmodule FermixCore.Watch.Supervisor do
  @moduledoc """
  Supervises the watch-mode infrastructure: a unique-key `Registry`
  (conversation_key → watch pid) and a `DynamicSupervisor` that owns the
  per-conversation `Watch.Session` processes.

  A `Watch.Session` is spawned lazily via `Watch.SessionManager.ensure/2` only
  when a watch is requested, and self-terminates at its max duration — so a bare
  registry + empty supervisor is inert. Mirrors `ComputerUse.Supervisor`.

  (App-tree wiring lands with the `watch`/`stop_watch` tools in a later stage;
  today this is started by its own callers/tests.)
  """

  use Supervisor

  @registry FermixCore.Watch.SessionRegistry
  @session_supervisor FermixCore.Watch.SessionSupervisor

  @spec registry() :: atom()
  def registry, do: @registry

  @spec session_supervisor() :: atom()
  def session_supervisor, do: @session_supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @session_supervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
