defmodule FermixCore.Realtime.ToolBridge do
  @moduledoc """
  Converts Realtime capability snapshots to provider tools and executes calls.
  """

  alias FermixCore.Capabilities.Capability

  @type t :: %__MODULE__{
          capabilities: %{String.t() => Capability.t()},
          context: map()
        }

  defstruct capabilities: %{}, context: %{}

  @spec new([Capability.t()], map()) :: t()
  def new(capabilities, context) when is_list(capabilities) and is_map(context) do
    %__MODULE__{
      capabilities: Map.new(capabilities, &{&1.name, &1}),
      context: context
    }
  end

  @spec to_openai_tools([Capability.t()]) :: [map()]
  def to_openai_tools(capabilities) when is_list(capabilities) do
    Enum.map(capabilities, fn %Capability{} = capability ->
      %{
        type: "function",
        name: capability.name,
        description: capability.description,
        parameters: capability.parameters
      }
    end)
  end

  @spec execute_call(t(), map()) ::
          {:ok, %{call_id: String.t(), output: String.t()}}
          | {:error, %{call_id: String.t(), reason: term()}}
  def execute_call(%__MODULE__{} = bridge, %{} = call) do
    call_id = Map.get(call, "call_id") || Map.get(call, :call_id) || ""
    name = Map.get(call, "name") || Map.get(call, :name)

    with {:ok, capability} <- fetch_capability(bridge, name),
         {:ok, args} <- decode_arguments(call),
         {:ok, result} <- execute_capability(capability, args, bridge.context) do
      {:ok, %{call_id: call_id, output: Jason.encode!(result)}}
    else
      {:error, reason} -> {:error, %{call_id: call_id, reason: reason}}
    end
  end

  defp fetch_capability(%__MODULE__{} = bridge, name) when is_binary(name) do
    case Map.fetch(bridge.capabilities, name) do
      {:ok, capability} -> {:ok, capability}
      :error -> {:error, {:unknown_tool, name}}
    end
  end

  defp fetch_capability(_bridge, name), do: {:error, {:unknown_tool, inspect(name)}}

  defp decode_arguments(call) do
    arguments = Map.get(call, "arguments") || Map.get(call, :arguments) || "{}"

    case Jason.decode(arguments) do
      {:ok, %{} = args} -> {:ok, args}
      {:ok, _other} -> {:error, :invalid_arguments_json}
      {:error, _reason} -> {:error, :invalid_arguments_json}
    end
  end

  defp execute_capability(%Capability{} = capability, args, context) do
    case Capability.execute(capability, args, context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_tool_result, other}}
    end
  end
end
