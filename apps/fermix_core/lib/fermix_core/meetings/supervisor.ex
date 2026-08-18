defmodule FermixCore.Meetings.Supervisor do
  @moduledoc """
  Supervises the meetings tree: the unique-key `Registry` (meeting id → Session
  pid), the `DynamicSupervisor` that owns the `:temporary` sessions, and the
  boot `Sweep`.

  It is in the application tree **unconditionally**, unlike the computer-use
  supervisor it otherwise resembles. Nothing here holds an OS process or opens a
  socket; nothing is spawned until `Meetings.join/2` starts a session. Keeping
  it always-on means enabling meetings from web setup takes effect without a
  daemon restart, and the boot sweep runs even for an install that has since
  been turned off. The enable gate lives in `join/2` and in the tool seeder,
  where a refusal can be explained.
  """

  use Supervisor

  alias FermixCore.Meetings.Sweep

  @registry FermixCore.Meetings.Registry
  @session_supervisor FermixCore.Meetings.SessionSupervisor

  @doc "The unique-key registry name: one live Session per meeting id."
  @spec registry() :: atom()
  def registry, do: @registry

  @doc "The DynamicSupervisor that owns the per-meeting Session processes."
  @spec session_supervisor() :: atom()
  def session_supervisor, do: @session_supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @session_supervisor, strategy: :one_for_one},
      {Sweep, Keyword.take(opts, [:store_opts])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
