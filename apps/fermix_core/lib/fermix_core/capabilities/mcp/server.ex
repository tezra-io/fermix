defmodule FermixCore.Capabilities.MCP.Server do
  @moduledoc """
  Per-server GenServer that owns the MCP tool registration lifecycle for
  one configured server.

  On init it discovers the server's tool list via the configured
  `Discoverer` (defaults to `Hermes` in production, swappable in tests),
  builds an `MCP.Capability` for each tool, and registers it with the
  capability registry. The Hermes client pid is published to
  `MCP.Registry` so dispatch can resolve `server_name -> client_pid`.

  On terminate it unregisters all of its capabilities (matched by
  `metadata.mcp_server`) and removes itself from the server registry.
  Discovery failures are logged and the GenServer exits — the parent
  supervisor decides the restart strategy.
  """

  use GenServer
  require Logger

  alias FermixCore.Capabilities.MCP.Capability, as: McpCapability
  alias FermixCore.Capabilities.MCP.Registry, as: McpRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry

  @type opt ::
          {:server_name, String.t()}
          | {:client, term()}
          | {:discoverer, module()}
          | {:caller, module()}
          | {:approved?, boolean()}
          | {:tools_overrides, %{String.t() => map()}}
          | {:capability_registry, GenServer.server()}
          | {:mcp_registry, GenServer.server()}

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      server_name: Keyword.fetch!(opts, :server_name),
      client: Keyword.get(opts, :client),
      discoverer: Keyword.get(opts, :discoverer, FermixCore.Capabilities.MCP.Discoverer.Hermes),
      caller: Keyword.get(opts, :caller, FermixCore.Capabilities.MCP.Caller.Hermes),
      tools_overrides: Keyword.get(opts, :tools_overrides, %{}),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      mcp_registry: Keyword.get(opts, :mcp_registry, McpRegistry),
      registered_names: [],
      discovery_attempts: 0,
      max_discovery_attempts: Keyword.get(opts, :max_discovery_attempts, 5),
      retry_base_ms: Keyword.get(opts, :retry_base_ms, 500),
      fail_fast?: Keyword.get(opts, :fail_fast?, false)
    }

    if state.fail_fast? do
      case discover_and_register(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, {:mcp_discovery_failed, state.server_name, reason}}
      end
    else
      {:ok, state, {:continue, :discover}}
    end
  end

  @impl true
  def handle_continue(:discover, state) do
    case discover_and_register(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        handle_discovery_failure(reason, state)
    end
  end

  @impl true
  def handle_info(:retry_discovery, state) do
    {:noreply, state, {:continue, :discover}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.registered_names, fn name ->
      CapabilityRegistry.unregister(state.capability_registry, name)
    end)

    if is_pid(state.client) do
      McpRegistry.unregister(state.mcp_registry, state.server_name)
    end

    :ok
  end

  defp discover_and_register(state) do
    with :ok <- maybe_register_client(state),
         {:ok, descriptors} <- state.discoverer.list_tools(state.client) do
      registered = Enum.flat_map(descriptors, &register_descriptor(&1, state))
      {:ok, %{state | registered_names: registered, discovery_attempts: 0}}
    end
  end

  defp handle_discovery_failure(reason, state) do
    attempts = state.discovery_attempts + 1
    state = %{state | discovery_attempts: attempts}

    if attempts >= state.max_discovery_attempts do
      Logger.error(
        "MCP server #{state.server_name} discovery failed #{attempts} times, giving up: " <>
          inspect(reason)
      )

      {:stop, :normal, state}
    else
      delay = state.retry_base_ms * round(:math.pow(2, attempts - 1))
      log_retry(reason, state.server_name, attempts, state.max_discovery_attempts, delay)
      Process.send_after(self(), :retry_discovery, delay)
      {:noreply, state}
    end
  end

  # `Server capabilities not set` is the expected response while the MCP
  # client is still racing through `initialize` — log at debug, not warning,
  # so a noisy `npx`-backed startup doesn't surface as a red flag to the
  # operator. Real errors (transport closed, unexpected response shape,
  # tool schema errors) keep the warning level.
  defp log_retry(reason, server_name, attempts, max_attempts, delay) do
    message =
      "MCP server #{server_name} discovery failed (attempt #{attempts}/#{max_attempts}); " <>
        "retrying in #{delay}ms: #{inspect(reason)}"

    if expected_startup_error?(reason),
      do: Logger.debug(message),
      else: Logger.warning(message)
  end

  defp expected_startup_error?(%Hermes.MCP.Error{reason: :internal_error, data: %{message: msg}})
       when is_binary(msg) do
    String.contains?(msg, "Server capabilities not set")
  end

  defp expected_startup_error?(_reason), do: false

  defp maybe_register_client(%{client: nil}), do: :ok

  defp maybe_register_client(%{client: client} = state) when is_pid(client) do
    McpRegistry.register(state.mcp_registry, state.server_name, client)
  end

  defp maybe_register_client(%{client: client} = state) when is_atom(client) do
    case Process.whereis(client) do
      pid when is_pid(pid) ->
        McpRegistry.register(state.mcp_registry, state.server_name, pid)

      nil ->
        {:error, {:hermes_client_not_started, client}}
    end
  end

  defp maybe_register_client(_state), do: :ok

  defp register_descriptor(descriptor, state) do
    overrides = Map.get(state.tools_overrides, descriptor.name, %{})

    capability =
      McpCapability.from_tool_descriptor(state.server_name, descriptor,
        caller: state.caller,
        tool_overrides: overrides
      )

    case CapabilityRegistry.register(state.capability_registry, capability) do
      :ok ->
        [capability.name]

      {:error, {:duplicate_name, _}} ->
        Logger.warning(
          "MCP duplicate capability name during registration: #{capability.name} " <>
            "(server=#{state.server_name}, tool=#{descriptor.name})"
        )

        []
    end
  end
end
