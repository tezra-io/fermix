defmodule FermixChannels.Test.DesktopFamilyHost do
  @moduledoc """
  A stand-in for `Desktop.Peer` that runs one `Desktop.Family` module in a
  process of its own, for tests that wire a primary's family to a desktop's
  handler in one VM: `{:event, type, fields, payload}` is handed to the
  family's `handle_event/4`, and `{:desktop_family, family, message}` (what
  `Peer.tell/4` and a registry subscription send) to its `handle_info/2`.

  `start/3` registers it in `:registry` (when given) under the device id, with
  the value a peer registers (`session`, `connected_since`), so
  `Desktop.Peer.lookup/2`, `connected/1` and `tell/4` find it, and hands the
  family that registry and `:options` in its context, as a peer does.
  """

  use GenServer

  @spec start(module(), map(), keyword()) :: pid()
  def start(module, context, opts \\ []) when is_atom(module) and is_map(context) do
    {:ok, pid} = GenServer.start(__MODULE__, {module, context, opts})
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  @doc "Hands the family one event, and answers what its `handle_event/4` answered."
  @spec event(pid(), String.t(), map(), binary()) :: :ok | {:error, term()}
  def event(host, type, fields, payload \\ <<>>),
    do: GenServer.call(host, {:event, type, fields, payload})

  @impl true
  def init({module, context, opts}) do
    case Keyword.get(opts, :registry) do
      nil ->
        :ok

      registry ->
        value = %{session: self(), connected_since: DateTime.utc_now()}
        {:ok, _owner} = Registry.register(registry, context.device_id, value)
    end

    context =
      Map.merge(context, %{
        peer: self(),
        registry: Keyword.get(opts, :registry),
        options: Keyword.get(opts, :options, [])
      })

    {:ok, family} = module.init(context)
    {:ok, %{module: module, family: family}}
  end

  @impl true
  def handle_call({:event, type, fields, payload}, _from, state) do
    case state.module.handle_event(type, fields, payload, state.family) do
      {:ok, family} -> {:reply, :ok, %{state | family: family}}
      {:error, reason, family} -> {:reply, {:error, reason}, %{state | family: family}}
    end
  end

  @impl true
  def handle_cast({:event, type, fields, payload}, state) do
    {:reply, _answer, state} = handle_call({:event, type, fields, payload}, nil, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:desktop_family, _family, message}, state) do
    {:ok, family} = state.module.handle_info(message, state.family)
    {:noreply, %{state | family: family}}
  end

  def handle_info({:mobile_sync, from, ref}, state) do
    send(from, {:mobile_synced, ref})
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state), do: state.module.terminate(reason, state.family)
end
