defmodule FermixCore.Capabilities.Builtin.Tool do
  @moduledoc """
  Behaviour for built-in tool implementations.

  Built-in tools live in `FermixCore.Tools.*` and surface as
  `kind: :builtin` capabilities through `FermixCore.Capabilities.Builtin.from_tool_module/1`.
  Each module declares its name/description/JSON-Schema parameters and a
  `c:execute/2` that returns a normalized result map.

  This behaviour replaces the older `FermixCore.Tools.Tool` behaviour
  removed in M4.9 Stage 7. Skill and MCP capabilities reuse `success/1`
  and `error/1` here so every capability returns the same result shape
  regardless of `kind`.
  """

  @type tool_result :: %{
          success: boolean(),
          output: String.t(),
          error: String.t() | nil
        }

  @type context :: %{
          required(:agent_name) => String.t(),
          required(:conversation_key) => term(),
          optional(atom()) => term()
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback execute(map(), context()) :: {:ok, tool_result()} | {:error, term()}

  @spec success(String.t()) :: tool_result()
  def success(output) when is_binary(output) do
    %{success: true, output: output, error: nil}
  end

  @spec error(String.t()) :: tool_result()
  def error(message) when is_binary(message) do
    %{success: false, output: "", error: message}
  end
end
