defmodule FermixChannels.Accessories.StoreWriter do
  @moduledoc """
  The one writer of a home's accessory pairing store
  (`FermixCore.Accessories.Store`, M91 §07): every link's writes (the host key
  made at the first `enroll.begin`, a record on `enroll.done`, a record erased
  on forget or revoke) go through this process, so two links never write the
  records' file at once. Reads need no writer: the store publishes each file
  in one step.

  The first child of the accessories subtree's `:rest_for_one` list, so it
  never raises on what it is handed or on the store's I/O: every store call
  returns a result, and the result goes back to the caller as it was.
  """

  use GenServer

  alias FermixCore.Accessories.HostKey
  alias FermixCore.Accessories.Record
  alias FermixCore.Accessories.Store

  require Logger

  # A write is a few small synced files; one that takes this long is stuck.
  @call_timeout_ms 10_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    home = Keyword.fetch!(opts, :home)

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, home)
      name -> GenServer.start_link(__MODULE__, home, name: name)
    end
  end

  @doc "The home's host key, made on first use (`Store.ensure_host_key/1`)."
  @spec ensure_host_key(GenServer.server()) :: {:ok, HostKey.t()} | {:error, term()}
  def ensure_host_key(writer), do: call(writer, :ensure_host_key)

  @doc "Records an enrolled accessory (`Store.put/2`)."
  @spec put(GenServer.server(), Record.t()) :: :ok | {:error, term()}
  def put(writer, %Record{} = record), do: call(writer, {:put, record})

  @doc "Erases one accessory's record (`Store.forget/2`)."
  @spec forget(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def forget(writer, accessory_id) when is_binary(accessory_id),
    do: call(writer, {:forget, accessory_id})

  @doc "The home this writer writes."
  @spec home(GenServer.server()) :: {:ok, Path.t()} | {:error, term()}
  def home(writer), do: call(writer, :home)

  @impl true
  def init(home) when is_binary(home) and home != "", do: {:ok, %{home: home}}

  @impl true
  def handle_call(:ensure_host_key, _from, state),
    do: {:reply, logged(:ensure_host_key, Store.ensure_host_key(state.home)), state}

  def handle_call({:put, record}, _from, state),
    do: {:reply, logged(:put, Store.put(state.home, record)), state}

  def handle_call({:forget, accessory_id}, _from, state),
    do: {:reply, logged(:forget, Store.forget(state.home, accessory_id)), state}

  def handle_call(:home, _from, state), do: {:reply, {:ok, state.home}, state}

  def handle_call(request, _from, state) do
    Logger.warning("accessory store writer refused an unknown call: #{inspect(request)}")
    {:reply, {:error, :unknown_call}, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.warning("accessory store writer ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # A refusal the caller acts on is logged here once, with the operation, so
  # the daemon log names which write failed.
  defp logged(_operation, :ok), do: :ok
  defp logged(_operation, {:ok, _value} = ok), do: ok
  defp logged(_operation, {:error, :unknown_accessory} = refused), do: refused

  defp logged(operation, {:error, reason} = error) do
    Logger.error("accessory store #{operation} failed: #{inspect(reason)}")
    error
  end

  defp call(writer, request) do
    GenServer.call(writer, request, @call_timeout_ms)
  catch
    :exit, reason ->
      Logger.error("accessory store writer unavailable: #{inspect(reason)}")
      {:error, :store_writer_unavailable}
  end
end
