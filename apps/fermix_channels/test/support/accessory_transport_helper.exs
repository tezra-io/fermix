defmodule FermixTestSupport.AccessoryBus do
  @moduledoc """
  An in-memory USB bus for the accessory link's tests: the ports enumeration
  finds, which of them is held, and the peer process (an
  `FermixTestSupport.AccessorySim`, or a test standing in for a port that
  gives no Fermix answer) behind each one. One bus per test, started with
  `start_supervised!/1`, so no test sees another's ports.

  A port is `%{serial, vendor_id, product_id, peer, busy?}`; `busy?` stands for
  another program holding it. Opening a held or busy port is `:busy`, a
  missing one `:not_found`. Unplugging a held port tells its owner
  `{:closed, :vanished}` through the transport, as a real one would.
  """

  use Agent

  @espressif 0x303A
  @usb_serial_jtag 0x1001

  def start_link(_opts), do: Agent.start_link(fn -> %{ports: %{}, held: %{}} end)

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Plugs a port in. `opts`: `:serial`, `:peer`, `:busy?`, `:vendor_id`, `:product_id`."
  def plug(bus, path, opts) do
    port = %{
      serial: Keyword.get(opts, :serial),
      vendor_id: Keyword.get(opts, :vendor_id, @espressif),
      product_id: Keyword.get(opts, :product_id, @usb_serial_jtag),
      peer: Keyword.get(opts, :peer),
      busy?: Keyword.get(opts, :busy?, false)
    }

    Agent.update(bus, &put_in(&1, [:ports, path], port))
  end

  @doc "Sets whether another program holds the port."
  def set_busy(bus, path, busy?),
    do: Agent.update(bus, &update_in(&1, [:ports, path], fn port -> %{port | busy?: busy?} end))

  @doc "Unplugs a port: its owner, if any, is told it vanished."
  def unplug(bus, path) do
    held =
      Agent.get_and_update(bus, fn state ->
        {Map.get(state.held, path),
         %{state | ports: Map.delete(state.ports, path), held: Map.delete(state.held, path)}}
      end)

    with {owner, ref} <- held, do: send(owner, {:accessory_bus, ref, {:closed, :vanished}})
    :ok
  end

  @doc "Who holds a port now: `{owner, ref}` or nil."
  def holder(bus, path), do: Agent.get(bus, &Map.get(&1.held, path))

  @doc false
  def ports(bus), do: Agent.get(bus, & &1.ports)

  @doc false
  def take(bus, path, owner) do
    Agent.get_and_update(bus, fn state -> take_port(state, path, owner) end)
  end

  defp take_port(state, path, owner) do
    # A port whose holder died is free again, as a real one is once the
    # process that held it is gone.
    case {Map.fetch(state.ports, path), held_alive?(state.held, path)} do
      {:error, _held} -> {{:error, :not_found}, state}
      {{:ok, %{busy?: true}}, _held} -> {{:error, :busy}, state}
      {{:ok, _port}, true} -> {{:error, :busy}, state}
      {{:ok, port}, false} -> held(state, path, owner, port)
    end
  end

  defp held_alive?(held, path) do
    case Map.get(held, path) do
      {owner, _ref} -> Process.alive?(owner)
      nil -> false
    end
  end

  defp held(state, path, owner, port) do
    ref = make_ref()
    {{:ok, ref, port.peer}, put_in(state, [:held, path], {owner, ref})}
  end

  @doc false
  def release(bus, path, ref) do
    Agent.update(bus, fn state ->
      case Map.get(state.held, path) do
        {_owner, ^ref} -> %{state | held: Map.delete(state.held, path)}
        _other -> state
      end
    end)
  end
end

defmodule FermixTestSupport.AccessoryMemoryTransport do
  @moduledoc """
  The accessory link's transport over `FermixTestSupport.AccessoryBus`, for
  tests (`FermixChannels.Accessories.Transport`). `transport_opts` carries
  `bus: pid`. The peer behind a port is told `{:accessory_port, :opened, ref,
  owner}` when a link opens it, gets every write as `{:accessory_port, :bytes,
  ref, binary}` and `{:accessory_port, :closed, ref}` on close; it answers the
  owner with `deliver/3`.
  """

  @behaviour FermixChannels.Accessories.Transport

  alias FermixTestSupport.AccessoryBus

  defstruct [:bus, :path, :ref, :peer]

  @impl true
  def enumerate(opts) do
    bus = Keyword.fetch!(opts, :bus)

    {:ok,
     for {path, port} <- AccessoryBus.ports(bus) do
       %{path: path, vendor_id: port.vendor_id, product_id: port.product_id, serial: port.serial}
     end}
  end

  @impl true
  def open(path, opts) do
    bus = Keyword.fetch!(opts, :bus)

    with {:ok, ref, peer} <- AccessoryBus.take(bus, path, self()) do
      if is_pid(peer), do: send(peer, {:accessory_port, :opened, ref, self()})
      {:ok, %__MODULE__{bus: bus, path: path, ref: ref, peer: peer}}
    end
  end

  @impl true
  def write(%__MODULE__{} = handle, iodata) do
    if is_pid(handle.peer),
      do: send(handle.peer, {:accessory_port, :bytes, handle.ref, IO.iodata_to_binary(iodata)})

    :ok
  end

  @impl true
  def close(%__MODULE__{} = handle) do
    # At a test's end the bus may already be gone.
    if Process.alive?(handle.bus), do: AccessoryBus.release(handle.bus, handle.path, handle.ref)
    if is_pid(handle.peer), do: send(handle.peer, {:accessory_port, :closed, handle.ref})
    :ok
  end

  @impl true
  def message(%__MODULE__{ref: ref}, {:accessory_bus, ref, message}), do: message
  def message(%__MODULE__{}, _message), do: :unknown

  @doc "The peer sends bytes (or a close) to the port's owner."
  def deliver(owner, ref, bytes) when is_binary(bytes),
    do: send(owner, {:accessory_bus, ref, {:data, bytes}})
end
