defmodule FermixCore.Computers.Remote do
  @moduledoc """
  A tool call that runs on one of the home's computers, on the server's side
  (M97 §6.4): when `Computers.Choice` chose a computer (`context.computer`),
  the tool sends one invocation in place of calling the sandbox itself, and
  the computer runs the same tool code under its own sandbox
  (`Computers.Capabilities.Files`, `Computers.Capabilities.Shell`).

  `run/6` is the whole call for a tool whose answer is its result: it asks
  the computer (`Computers.call/6`, with the capability's own deadline,
  `deadline_ms/2`), turns the answer into the tool result the model reads,
  and emits the call's one `[:fermix, :tool, :exec]` event under the tool's
  name, with the computer and the invocation's outcome in its metadata
  (`Outcome.exec_metadata/1`). A tool that acts on the answer itself
  (`send_attachment`) uses `invoke/5`, `result/2` and `exec/6` in its place.

  **Every result names the computer**, so the model never mixes the server's
  paths with a computer's: the tool's own words follow "On <name>:", and
  every other ending is `Outcome.sentence/2`'s, which names it too. A path
  outside that computer's sandbox says it is allowed only at that computer.

  The context's `:computer_call_opts` (a keyword) reach `Computers.call/6`,
  where a test names its `Calls`, transport and epoch.
  """

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Computers
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Offers.Files
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.ToolResult
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @max_error_summary 500

  @doc "The computer `Computers.Choice` chose for the call, or nil when it runs here."
  @spec computer(map()) :: Computer.t() | nil
  def computer(%{computer: %Computer{} = computer}), do: computer
  def computer(context) when is_map(context), do: nil

  @doc "Runs `op` of `module` with `args` on the chosen computer: the moduledoc's `run`."
  @spec run(String.t(), module(), String.t(), map(), map(), keyword()) ::
          {:ok, Tool.tool_result()}
  def run(tool, module, op, args, context, opts \\ [])
      when is_binary(tool) and is_atom(module) and is_binary(op) and is_map(args) and
             is_map(context) and is_list(opts) do
    started = System.monotonic_time(:millisecond)
    {_ok_or_error, outcome} = invoke(module, op, args, context, opts)
    result = result(outcome, computer!(context))
    :ok = exec(tool, context, outcome, result, args, started)
    {:ok, result}
  end

  @doc "Asks the chosen computer to run `op` and waits for its answer."
  @spec invoke(module(), String.t(), map(), map(), keyword()) ::
          {:ok, Outcome.t()} | {:error, Outcome.t()}
  def invoke(module, op, args, context, opts \\ [])
      when is_atom(module) and is_binary(op) and is_map(args) and is_map(context) and
             is_list(opts) do
    call_opts =
      context
      |> Map.get(:computer_call_opts, [])
      |> Keyword.put(:deadline_ms, deadline_ms(module, op, args))
      |> Keyword.merge(opts)

    Computers.call(computer!(context), module, op, args, context, call_opts)
  end

  @doc """
  The tool result the model reads for `outcome` on `computer`: the tool's own
  result where it ran, whether it succeeded (`ok`) or failed with a result
  of its own (`failed`, the whole error, not only the outcome's first line),
  else the outcome's sentence (the moduledoc). One that ran and whose output
  was lost on the way (`part_lost`) says so in its sentence. A result that
  says otherwise than its status is not a tool's result.
  """
  @spec result(Outcome.t(), Computer.t()) :: Tool.tool_result()
  def result(%Outcome{status: :ok, receipt_only: true} = outcome, %Computer{name: name}),
    do: Tool.success(Outcome.sentence(outcome, name))

  # It ran, and its output was lost on the way: said so, in the status it
  # ran to, never a failure that would have it run again.
  def result(%Outcome{status: :ok, part_lost: true} = outcome, %Computer{name: name}),
    do: Tool.success(Outcome.sentence(outcome, name))

  def result(%Outcome{status: :failed, part_lost: true} = outcome, %Computer{name: name}),
    do: Tool.error(Outcome.sentence(outcome, name))

  def result(%Outcome{status: :ok} = outcome, %Computer{} = computer),
    do: tool_result(outcome, true, computer)

  def result(%Outcome{status: :failed, result: %{"success" => _said}} = outcome, %Computer{} = c),
    do: tool_result(outcome, false, c)

  # The folders that computer's files and commands reach, from what it
  # offers, so the model asks for one of them (M97 §6.4, finding F5).
  def result(%Outcome{status: :refused, refusal: :outside_sandbox} = outcome, %Computer{} = c),
    do:
      Tool.error(
        "On #{c.name}: #{outcome.message}#{reach(Files.reach(c.offers, c.name))} Someone at #{c.name} " <>
          "can allow the folder; it cannot be allowed from here."
      )

  def result(%Outcome{} = outcome, %Computer{name: name}),
    do: Tool.error(Outcome.sentence(outcome, name))

  @doc """
  The call's one exec event under `tool`: success is the tool's own, and the
  metadata carries the computer, the invocation and how it ended, and the
  error's first words when it failed.
  """
  @spec exec(String.t(), map(), Outcome.t(), Tool.tool_result(), map(), integer()) :: :ok
  def exec(tool, context, %Outcome{} = outcome, %{success: success} = result, args, started)
      when is_binary(tool) and is_map(context) and is_map(args) and is_integer(started) do
    duration = max(System.monotonic_time(:millisecond) - started, 0)

    ToolTelemetry.exec(tool, context, success, duration,
      metadata: outcome |> Outcome.exec_metadata() |> put_error(result),
      input: args,
      result: {:ok, Map.delete(result, :images)}
    )
  end

  defp tool_result(%Outcome{result: %{"success" => success}} = outcome, success, %Computer{} = c) do
    case ToolResult.decode(outcome.result, outcome.part_bytes) do
      {:ok, result} -> named(result, c.name)
      {:error, sentence} -> Tool.error("On #{c.name}: #{sentence}")
    end
  end

  defp tool_result(%Outcome{}, _success, %Computer{name: name}),
    do: Tool.error("On #{name}: #{ToolResult.not_a_result()}")

  defp named(%{success: true, output: output} = result, name),
    do: %{result | output: "On #{name}:\n" <> output}

  defp named(%{success: false, error: error} = result, name),
    do: %{result | error: "On #{name}: " <> error}

  defp put_error(metadata, %{success: false, error: error}) when is_binary(error),
    do: Map.put(metadata, :error_summary, String.slice(error, 0, @max_error_summary))

  defp put_error(metadata, _result), do: metadata

  defp reach(nil), do: ""
  defp reach(reach), do: " #{reach}."

  defp deadline_ms(module, op, args) do
    if Code.ensure_loaded?(module) and function_exported?(module, :deadline_ms, 2),
      do: module.deadline_ms(op, args),
      else: 30_000
  end

  defp computer!(%{computer: %Computer{} = computer}), do: computer

  defp computer!(_context),
    do: raise(ArgumentError, "a call runs on a computer only once Computers.Choice chose one")
end
