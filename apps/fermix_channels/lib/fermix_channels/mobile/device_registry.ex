defmodule FermixChannels.Mobile.DeviceRegistry do
  @moduledoc """
  Serialized presence registry for Bandit-owned mobile WebSocket processes.

  Bandit, not a `DynamicSupervisor`, owns each socket process. This GenServer
  monitors those processes and makes replacement atomic: attaching a new socket
  stores it before notifying the old one, so stale `terminate/2` and `:DOWN`
  cleanup can never remove the replacement.
  """

  use GenServer

  alias FermixChannels.Mobile.DeviceStore

  @type device_id :: String.t()
  @type profile_id :: String.t()
  @type entry :: %{device_id: device_id(), pid: pid(), profile_id: profile_id()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec attach(GenServer.server(), device_id(), pid()) :: :ok | {:error, term()}
  def attach(server, device_id, pid)
      when is_binary(device_id) and device_id != "" and is_pid(pid) do
    attach(server, device_id, pid, [])
  end

  @spec attach(GenServer.server(), device_id(), pid(), keyword() | map()) ::
          :ok | {:error, term()}
  def attach(server, device_id, pid, opts)
      when is_binary(device_id) and device_id != "" and is_pid(pid) and
             (is_list(opts) or is_map(opts)) do
    GenServer.call(server, {:attach, device_id, pid, opts})
  end

  @spec lookup(GenServer.server(), device_id()) :: {:ok, pid()} | {:error, :not_connected}
  def lookup(server, device_id) when is_binary(device_id) and device_id != "" do
    GenServer.call(server, {:lookup, device_id})
  end

  @spec list(GenServer.server()) :: [entry()]
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  @spec connected(GenServer.server(), profile_id()) :: [{device_id(), pid()}]
  def connected(server \\ __MODULE__, profile_id \\ "main")
      when is_binary(profile_id) and profile_id != "" do
    GenServer.call(server, {:connected, profile_id})
  end

  @spec detach(GenServer.server(), device_id(), pid()) :: :ok
  def detach(server, device_id, pid)
      when is_binary(device_id) and device_id != "" and is_pid(pid) do
    GenServer.call(server, {:detach, device_id, pid})
  end

  @spec revoke(GenServer.server(), device_id()) :: :ok
  def revoke(server, device_id) when is_binary(device_id) and device_id != "" do
    GenServer.call(server, {:revoke, device_id})
  end

  @doc "Verify that a ready socket is still the current durable authorization."
  @spec authorized?(GenServer.server(), device_id(), pid()) :: :ok | {:error, term()}
  def authorized?(server, device_id, pid)
      when is_binary(device_id) and device_id != "" and is_pid(pid) do
    GenServer.call(server, {:authorized, device_id, pid})
  end

  @doc "Send a logical event to one socket for per-session encryption."
  @spec send_device_event(device_id(), map()) :: :ok | {:error, :not_connected}
  def send_device_event(device_id, event)
      when is_binary(device_id) and device_id != "" and is_map(event) do
    send_device_event(__MODULE__, device_id, event)
  end

  @spec send_device_event(GenServer.server(), device_id(), map()) ::
          :ok | {:error, :not_connected}
  def send_device_event(server, device_id, event)
      when is_binary(device_id) and device_id != "" and is_map(event) do
    GenServer.call(server, {:send_device_event, device_id, event})
  end

  @doc "Fan a logical event out to a profile for per-session encryption."
  @spec send_profile_event(profile_id(), map()) :: non_neg_integer()
  def send_profile_event(profile_id, event)
      when is_binary(profile_id) and profile_id != "" and is_map(event) do
    send_profile_event(__MODULE__, profile_id, event)
  end

  @spec send_profile_event(GenServer.server(), profile_id(), map()) :: non_neg_integer()
  def send_profile_event(server, profile_id, event)
      when is_binary(profile_id) and profile_id != "" and is_map(event) do
    GenServer.call(server, {:send_profile_event, profile_id, event})
  end

  @impl true
  def init(opts) when is_list(opts) do
    {:ok,
     %{
       by_device: %{},
       by_pid: %{},
       by_ref: %{},
       device_store: Keyword.get(opts, :device_store, DeviceStore),
       authorize_device: Keyword.get(opts, :authorize_device, &DeviceStore.fetch/2),
       delete_device: Keyword.get(opts, :delete_device, &DeviceStore.delete/2)
     }}
  end

  @impl true
  def handle_call({:attach, device_id, pid, opts}, _from, state) do
    profile_id = option(opts, :profile_id, "main")

    {reply, state} =
      with :ok <- authorize_device(state, device_id) do
        attach_socket(state, device_id, pid, profile_id)
      else
        {:error, reason} -> {{:error, reason}, state}
      end

    {:reply, reply, state}
  end

  def handle_call({:lookup, device_id}, _from, state) do
    reply =
      case Map.get(state.by_device, device_id) do
        nil -> {:error, :not_connected}
        entry -> {:ok, entry.pid}
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    entries = state.by_device |> Map.values() |> Enum.map(&public_entry/1) |> sort_entries()
    {:reply, entries, state}
  end

  def handle_call({:connected, profile_id}, _from, state) do
    connected =
      state.by_device
      |> Map.values()
      |> Enum.filter(&(&1.profile_id == profile_id))
      |> Enum.map(&{&1.device_id, &1.pid})
      |> Enum.sort_by(&elem(&1, 0))

    {:reply, connected, state}
  end

  def handle_call({:detach, device_id, pid}, _from, state) do
    {:reply, :ok, remove_if_current(state, device_id, pid)}
  end

  def handle_call({:revoke, device_id}, _from, state) do
    case state.delete_device.(state.device_store, device_id) do
      :ok ->
        {:reply, :ok, revoke_presence(state, device_id)}

      {:error, {:device_not_found, ^device_id}} = missing ->
        {:reply, missing, revoke_presence(state, device_id)}

      {:error, _reason} = error ->
        {:reply, error, state}

      other ->
        {:reply, {:error, {:invalid_device_delete_reply, other}}, state}
    end
  end

  def handle_call({:authorized, device_id, pid}, _from, state) do
    case Map.get(state.by_device, device_id) do
      %{pid: ^pid} -> reply_authorization(state, device_id)
      _missing_or_replaced -> {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:send_device_event, device_id, event}, _from, state) do
    case Map.get(state.by_device, device_id) do
      nil ->
        {:reply, {:error, :not_connected}, state}

      entry ->
        send(entry.pid, {:mobile_event, event})
        {:reply, :ok, state}
    end
  end

  def handle_call({:send_profile_event, profile_id, event}, _from, state) do
    entries = Enum.filter(Map.values(state.by_device), &(&1.profile_id == profile_id))
    Enum.each(entries, &send(&1.pid, {:mobile_event, event}))
    {:reply, length(entries), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {:noreply, remove_down(state, ref, pid)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp attach_socket(state, _device_id, pid, _profile_id) when not is_pid(pid),
    do: {{:error, :invalid_socket}, state}

  defp attach_socket(state, device_id, pid, profile_id) do
    cond do
      not valid_profile?(profile_id) ->
        {{:error, :invalid_profile_id}, state}

      not Process.alive?(pid) ->
        {{:error, :socket_not_alive}, state}

      Map.has_key?(state.by_pid, pid) and state.by_pid[pid] != device_id ->
        {{:error, {:socket_already_attached, state.by_pid[pid]}}, state}

      true ->
        {:ok, put_socket(state, device_id, pid, profile_id)}
    end
  end

  defp authorize_device(state, device_id) do
    case state.authorize_device.(state.device_store, device_id) do
      {:ok, _device} -> :ok
      {:error, reason} -> {:error, {:device_not_authorized, reason}}
      other -> {:error, {:invalid_device_authorization_reply, other}}
    end
  end

  defp reply_authorization(state, device_id) do
    case authorize_device(state, device_id) do
      :ok ->
        {:reply, :ok, state}

      {:error, _reason} = error ->
        {:reply, error, revoke_presence(state, device_id)}
    end
  end

  defp revoke_presence(state, device_id) do
    case Map.get(state.by_device, device_id) do
      nil ->
        state

      entry ->
        send(entry.pid, {:mobile_revoked, device_id})
        remove_entry(state, entry)
    end
  end

  defp put_socket(state, device_id, pid, profile_id) do
    case Map.get(state.by_device, device_id) do
      %{pid: ^pid} = entry ->
        put_in(state, [:by_device, device_id], %{entry | profile_id: profile_id})

      old_entry ->
        ref = Process.monitor(pid)
        entry = %{device_id: device_id, pid: pid, profile_id: profile_id, ref: ref}
        state = replace_entry(state, entry, old_entry)
        if old_entry, do: send(old_entry.pid, {:mobile_replaced, pid})
        state
    end
  end

  defp replace_entry(state, entry, nil) do
    state
    |> put_in([:by_device, entry.device_id], entry)
    |> put_in([:by_pid, entry.pid], entry.device_id)
    |> put_in([:by_ref, entry.ref], {entry.device_id, entry.pid})
  end

  defp replace_entry(state, entry, old_entry) do
    Process.demonitor(old_entry.ref, [:flush])

    state
    |> update_in([:by_pid], &Map.delete(&1, old_entry.pid))
    |> update_in([:by_ref], &Map.delete(&1, old_entry.ref))
    |> replace_entry(entry, nil)
  end

  defp remove_if_current(state, device_id, pid) do
    case Map.get(state.by_device, device_id) do
      %{pid: ^pid} = entry -> remove_entry(state, entry)
      _stale_or_missing -> state
    end
  end

  defp remove_down(state, ref, pid) do
    case Map.get(state.by_ref, ref) do
      {device_id, ^pid} -> remove_if_current(state, device_id, pid)
      _stale_or_missing -> state
    end
  end

  defp remove_entry(state, entry) do
    Process.demonitor(entry.ref, [:flush])

    state
    |> update_in([:by_device], &Map.delete(&1, entry.device_id))
    |> update_in([:by_pid], &Map.delete(&1, entry.pid))
    |> update_in([:by_ref], &Map.delete(&1, entry.ref))
  end

  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp option(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  defp public_entry(entry), do: Map.take(entry, [:device_id, :pid, :profile_id])
  defp sort_entries(entries), do: Enum.sort_by(entries, & &1.device_id)
  defp valid_profile?(profile_id), do: is_binary(profile_id) and profile_id != ""
end
