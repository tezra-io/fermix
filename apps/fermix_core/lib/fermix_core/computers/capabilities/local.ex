defmodule FermixCore.Computers.Capabilities.Local do
  @moduledoc """
  What the `files` and `shell` capabilities share on the computer (M97
  §6.4): each runs the tool's own code (its `perform/2`, the call without its
  exec event, which is the server's) under this computer's sandbox, which
  the invocation's context carries (`context.sandbox`, this computer's mode,
  roots, blocked roots and environment allow list), never application
  environment and never anything the server sent.

  `tool_context/1` is the context a tool runs with here; `admit_path/4` is
  the capability's own sandbox rule before anything runs (a path outside
  this computer's roots is refused `outside_sandbox`; a protected or blocked
  path is left to the tool, which refuses it in its own words, as it does
  locally); `ran/1` puts the tool's result on the wire
  (`Computers.ToolResult`), a tool's failure as a failed invocation.
  """

  alias FermixCore.Capabilities.Builtin.Tool
  alias FermixCore.Computers.Outcome
  alias FermixCore.Computers.ToolResult
  alias FermixCore.Sandbox
  alias FermixCore.Sandbox.Config

  @typedoc "How a path is checked: read, written, or a folder a command or git runs in."
  @type path_use :: :read | :write | :folder

  @doc """
  The context a tool runs with on this computer for the invocation whose
  context is `context`: this computer's sandbox, no turn folder (the turn's
  is the server's), and the invocation as its conversation.
  """
  @spec tool_context(map()) :: map()
  def tool_context(%{id: id, sandbox: %Config{} = sandbox}) when is_binary(id) do
    %{agent_name: "computer", conversation_key: {:invocation, id}, sandbox_config: sandbox}
  end

  @doc """
  `:ok`, or the refusal of a `path` outside this computer's sandbox roots,
  checked for `path_use` as the tool checks it. Anything but a non-empty path is
  the tool's to refuse.
  """
  @spec admit_path(term(), path_use(), atom(), map()) ::
          :ok | {:refused, Outcome.refusal(), String.t()}
  def admit_path(path, path_use, operation, context)
      when path_use in [:read, :write, :folder] and is_atom(operation) and is_map(context) do
    if is_binary(path) and path != "",
      do: outside(check(path, path_use, operation, tool_context(context))),
      else: :ok
  end

  @doc "Each path of `paths` admitted as `admit_path/4` does, the first refusal ending it."
  @spec admit_paths(term(), path_use(), atom(), map()) ::
          :ok | {:refused, Outcome.refusal(), String.t()}
  def admit_paths(paths, path_use, operation, context) when is_list(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case admit_path(path, path_use, operation, context) do
        :ok -> {:cont, :ok}
        refused -> {:halt, refused}
      end
    end)
  end

  def admit_paths(_not_a_list, _use, _operation, _context), do: :ok

  @doc """
  The tool's result as the invocation answers it: `ok` when the tool
  succeeded; `failed` when it did not, its message the first line of the
  tool's error that says something, with the whole result and its part
  still carried, so the journal and the server's exec event tell a failed
  command from one that ran clean and the model still reads every word.
  """
  @spec ran({:ok, Tool.tool_result()}) ::
          {:ok, map(), binary() | nil} | {:failed, String.t(), map(), binary() | nil}
  def ran({:ok, %{success: true} = result}) do
    {json, part} = ToolResult.encode(result)
    {:ok, json, part}
  end

  def ran({:ok, %{success: false, error: error} = result}) when is_binary(error) do
    {json, part} = ToolResult.encode(result)
    {:failed, first_said(error), json, part}
  end

  # Empty when no line says anything: `Outcome.to_wire/1` gives that its own
  # sentence.
  defp first_said(error) do
    error
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp check(path, :read, operation, context), do: Sandbox.read_path(path, operation, context)
  defp check(path, :write, operation, context), do: Sandbox.write_path(path, operation, context)
  defp check(path, :folder, operation, context), do: Sandbox.working_dir(path, operation, context)

  defp outside({:error, {:outside_root, denied}}),
    do: {:refused, :outside_sandbox, "#{denied} is outside this computer's sandbox."}

  defp outside(_allowed_or_the_tools_to_say), do: :ok
end
