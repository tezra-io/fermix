defmodule FermixCore.Tools.Registry do
  @moduledoc """
  GenServer-based registry for dynamic tool management.

  Stores registered tool modules and provides lookup by name.
  Started under the application supervisor.
  """

  use GenServer

  alias FermixCore.Tools.Tool

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, _opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @spec register(GenServer.server(), module()) :: :ok | {:error, :already_registered}
  def register(server \\ __MODULE__, tool_module) do
    GenServer.call(server, {:register, tool_module})
  end

  @spec all_tools(GenServer.server()) :: [module()]
  def all_tools(server \\ __MODULE__) do
    GenServer.call(server, :all_tools)
  end

  @spec all_tools_for_llm(GenServer.server()) :: [map()]
  def all_tools_for_llm(server \\ __MODULE__) do
    GenServer.call(server, :all_tools_for_llm)
  end

  @spec all_tools_for_llm(GenServer.server(), [String.t()] | nil) :: [map()]
  def all_tools_for_llm(server, allowed_tools)
      when is_list(allowed_tools) or is_nil(allowed_tools) do
    GenServer.call(server, {:all_tools_for_llm, allowed_tools})
  end

  @spec find_tool(GenServer.server(), String.t()) :: {:ok, module()} | :error
  def find_tool(server \\ __MODULE__, name) when is_binary(name) do
    GenServer.call(server, {:find_tool, name})
  end

  @spec find_tool(GenServer.server(), String.t(), [String.t()] | nil) ::
          {:ok, module()} | {:error, :not_allowed} | :error
  def find_tool(server, name, allowed_tools)
      when is_binary(name) and (is_list(allowed_tools) or is_nil(allowed_tools)) do
    GenServer.call(server, {:find_tool, name, allowed_tools})
  end

  # --- Server Callbacks ---

  @impl true
  def init([]) do
    {:ok, []}
  end

  @impl true
  def handle_call({:register, tool_module}, _from, tools) do
    if tool_module in tools do
      {:reply, {:error, :already_registered}, tools}
    else
      {:reply, :ok, tools ++ [tool_module]}
    end
  end

  def handle_call(:all_tools, _from, tools) do
    {:reply, tools, tools}
  end

  def handle_call(:all_tools_for_llm, _from, tools) do
    formatted = Enum.map(tools, &Tool.format_for_llm/1)
    {:reply, formatted, tools}
  end

  def handle_call({:all_tools_for_llm, allowed_tools}, _from, tools) do
    formatted =
      tools
      |> Enum.filter(&tool_allowed?(&1, allowed_tools))
      |> Enum.map(&Tool.format_for_llm/1)

    {:reply, formatted, tools}
  end

  def handle_call({:find_tool, name}, _from, tools) do
    result =
      case Enum.find(tools, fn tool -> tool.name() == name end) do
        nil -> :error
        tool -> {:ok, tool}
      end

    {:reply, result, tools}
  end

  def handle_call({:find_tool, name, allowed_tools}, _from, tools) do
    result =
      case Enum.find(tools, fn tool -> tool.name() == name end) do
        nil ->
          :error

        tool ->
          if tool_allowed?(tool, allowed_tools) do
            {:ok, tool}
          else
            {:error, :not_allowed}
          end
      end

    {:reply, result, tools}
  end

  defp tool_allowed?(_tool, nil), do: true
  defp tool_allowed?(tool, allowed_tools), do: tool.name() in allowed_tools
end
