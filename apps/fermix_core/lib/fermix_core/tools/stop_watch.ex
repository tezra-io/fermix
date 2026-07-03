defmodule FermixCore.Tools.StopWatch do
  @moduledoc """
  Stop the active live watch for this conversation (started by `watch`). Idempotent
  — a no-op when nothing is watching.
  """

  @behaviour FermixCore.Capabilities.Builtin.Tool

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry
  alias FermixCore.Watch.SessionManager

  @impl true
  def name, do: "stop_watch"

  @impl true
  def description do
    "Stop the active watch for this conversation (started by `watch`). " <>
      "No-op if none is running."
  end

  @impl true
  def parameters do
    %{type: "object", required: [], properties: %{}}
  end

  @impl true
  def when_to_use do
    "Stop a running live watch when the user says to stop watching, never mind, or " <>
      "that's enough."
  end

  @impl true
  def examples, do: [%{args: %{}, note: "stop the current watch"}]

  @impl true
  def failure_modes, do: []

  @impl true
  def requires_setup, do: nil

  @impl true
  def category, do: :gui

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    start = System.monotonic_time(:millisecond)
    result = do_execute(context)
    duration = System.monotonic_time(:millisecond) - start
    success = match?({:ok, %{success: true}}, result)

    ToolTelemetry.exec(name(), context, success, duration, input: args, result: result)
    result
  end

  defp do_execute(context) do
    :ok = SessionManager.abort(context)
    {:ok, Tool.success("Stopped watching.")}
  end
end
