defmodule FermixChannels.Desktop.MediaFetches do
  @moduledoc """
  The media family of a desktop's link (M75 §6, M97 §5.1), in the device
  role: writes each blob the relay fetches from its primary for its app into
  the staging directory (`Desktop.Relay.Media`), in a process of its own, so
  a slow disk never holds the relay, a chat line or a settings answer.

  The relay keeps who waits for which blob and hands this process the
  primary's media frames as they come, in order (`begin/5`, `chunk/4`,
  `finish/2`), never waiting on it. One transfer at a time, as the primary
  streams them: a begin abandons the transfer before it. Each transfer ends
  in `{:relay_media_done, ref, result}` to the relay that began it, the
  staged media or why not. A begin for a ref nobody waits for (`wanted?`
  false) is left unstaged, and its chunks with it. `drop/2` abandons a
  transfer the relay gave up on (the primary refused it, or the relay's
  hand-off here was full) with no word back, `abort/1` the transfer in
  progress when the session ends, and `discard/2` removes a staged blob
  nobody waits for.

  The staging directory is prepared (made `0700`, emptied of what a previous
  run left) as it starts; one that cannot be is logged, and each fetch then
  fails by name. Started under `Desktop.DeviceServices`, before the relay.
  Seams: `:name`, `:staging` (else under `:home`).
  """

  use GenServer

  require Logger

  alias FermixChannels.Desktop.Relay.Media
  alias FermixCore.Setup.ConfigStore

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The primary's `media_begin`: staged when `wanted?`, within `max_bytes`;
  its end is told to `relay`.
  """
  @spec begin(GenServer.server(), pid(), map(), boolean(), pos_integer()) :: :ok
  def begin(server, relay, %{"ref" => ref} = fields, wanted?, max_bytes)
      when is_pid(relay) and is_binary(ref) and is_boolean(wanted?) and is_integer(max_bytes),
      do: GenServer.cast(server, {:begin, relay, fields, wanted?, max_bytes})

  @doc "One `media_chunk` of `ref`."
  @spec chunk(GenServer.server(), String.t(), non_neg_integer(), binary()) :: :ok
  def chunk(server, ref, index, bytes) when is_binary(ref) and is_binary(bytes),
    do: GenServer.cast(server, {:chunk, ref, index, bytes})

  @doc "The `media_end` of `ref`: checked and staged, and the relay told."
  @spec finish(GenServer.server(), String.t()) :: :ok
  def finish(server, ref) when is_binary(ref), do: GenServer.cast(server, {:finish, ref})

  @doc "Abandons the transfer of `ref`, if it is the one in progress, with no word back."
  @spec drop(GenServer.server(), String.t()) :: :ok
  def drop(server, ref) when is_binary(ref), do: GenServer.cast(server, {:drop, ref})

  @doc "Abandons the transfer in progress: the session it came on ended."
  @spec abort(GenServer.server()) :: :ok
  def abort(server), do: GenServer.cast(server, :abort)

  @doc "Removes the staged blob of `ref`, which nobody waits for."
  @spec discard(GenServer.server(), String.t()) :: :ok
  def discard(server, ref) when is_binary(ref), do: GenServer.cast(server, {:discard, ref})

  @impl true
  def init(opts) do
    staging =
      Keyword.get_lazy(opts, :staging, fn ->
        Media.staging_dir(Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0))
      end)

    :ok = prepare(staging)
    {:ok, %{staging: staging, transfer: nil, relay: nil}}
  end

  @impl true
  def handle_cast({:begin, relay, %{"ref" => ref} = fields, wanted?, max_bytes}, state) do
    state = abandon(state)

    with true <- wanted?,
         {:ok, transfer} <- Media.begin(state.staging, fields, max_bytes) do
      {:noreply, %{state | transfer: transfer, relay: relay}}
    else
      false -> {:noreply, state}
      {:error, reason} -> {:noreply, done(relay, ref, {:error, reason}, state)}
    end
  end

  def handle_cast({:chunk, ref, index, bytes}, %{transfer: %{ref: ref} = transfer} = state) do
    case Media.chunk(transfer, index, bytes) do
      {:ok, transfer} -> {:noreply, %{state | transfer: transfer}}
      {:error, reason} -> {:noreply, done(state.relay, ref, {:error, reason}, abandon(state))}
    end
  end

  def handle_cast({:finish, ref}, %{transfer: %{ref: ref} = transfer} = state) do
    result = Media.finish(transfer, state.staging)
    {:noreply, done(state.relay, ref, result, %{state | transfer: nil})}
  end

  # A chunk or an end of a blob whose start was refused here, or left unstaged.
  def handle_cast({:chunk, _ref, _index, _bytes}, state), do: {:noreply, state}
  def handle_cast({:finish, _ref}, state), do: {:noreply, state}

  def handle_cast({:drop, ref}, %{transfer: %{ref: ref}} = state), do: {:noreply, abandon(state)}
  def handle_cast({:drop, _ref}, state), do: {:noreply, state}
  def handle_cast(:abort, state), do: {:noreply, abandon(state)}

  def handle_cast({:discard, ref}, state) do
    :ok = Media.discard(state.staging, ref)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _state = abandon(state)
    :ok
  end

  # A staging directory that cannot be prepared costs the app's media, never
  # the link; it is logged, and each fetch then fails by name.
  defp prepare(staging) do
    case Media.prepare(staging) do
      :ok -> :ok
      {:error, reason} -> Logger.error("desktop media: staging: #{inspect(reason)}")
    end

    :ok
  end

  defp abandon(%{transfer: nil} = state), do: state

  defp abandon(state) do
    :ok = Media.abort(state.transfer)
    %{state | transfer: nil}
  end

  defp done(relay, ref, result, state) do
    send(relay, {:relay_media_done, ref, result})
    %{state | relay: relay}
  end
end
