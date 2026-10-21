defmodule FermixCore.Management.McpServers.PastedValues do
  @moduledoc """
  The values a pasted text carried for one MCP server (M74 §5, E8): each by the
  `Capabilities.MCP.Secrets` ref it would be stored under, `{:env, NAME}`,
  `{:header, Name}` or `:client_secret`, until `mcp.servers.add` stores them.

  They are secrets until proven otherwise, so `inspect` shows none of them, nor
  their names: a crash report or a state dump that carries this struct prints
  the struct's name and `...`, nothing else. They live in the daemon's memory alone
  (`McpServers.DraftValues`), never on disk and never in a log.

  A header is found by name without regard to case, as HTTP names it, so a key
  the form spells `authorization` takes the value pasted under `Authorization`.
  """

  @derive {Inspect, only: []}
  defstruct values: %{}

  @type ref :: FermixCore.Capabilities.MCP.Secrets.ref()
  @type t :: %__MODULE__{values: %{ref() => String.t()}}

  @doc "Values by the ref each would be stored under."
  @spec new(%{ref() => String.t()}) :: t()
  def new(values) when is_map(values), do: %__MODULE__{values: values}

  @doc "Whether the paste carried no value at all."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{values: values}), do: values == %{}

  @doc "Whether the paste carried a value for `ref`."
  @spec carries?(t(), ref()) :: boolean()
  def carries?(%__MODULE__{} = pasted, ref), do: match?({:ok, _value}, fetch(pasted, ref))

  @doc "The value the paste carried for `ref`."
  @spec fetch(t(), ref()) :: {:ok, String.t()} | :error
  def fetch(%__MODULE__{values: values}, {:header, name}) do
    folded = String.downcase(name)

    Enum.find_value(values, :error, fn
      {{:header, pasted}, value} -> if String.downcase(pasted) == folded, do: {:ok, value}
      _other -> nil
    end)
  end

  def fetch(%__MODULE__{values: values}, ref), do: Map.fetch(values, ref)
end
