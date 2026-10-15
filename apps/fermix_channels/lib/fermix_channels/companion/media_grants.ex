defmodule FermixChannels.Companion.MediaGrants do
  @moduledoc """
  The one owner of the media files the daemon grants to companion connections.

  A `media_fetch` (companion protocol 3) names a ref a timeline row carries; the
  connection asks here for a file holding its bytes and sends the client the
  path. The file is a copy of the mobile store's blob, made once per ref at
  `<root>/<ref><ext>` (the extension `Gateway.MediaDownload.extension/1` gives
  every inbound copy) and left read-only. It is checked while it is copied: its
  size must be the one the row names and its sha256 the ref, or the grant
  answers `:media_missing`, as it does when the store no longer holds the bytes
  or the phone channel whose store keeps them is off. The stored original is
  never handed out, and nothing is decoded or rendered here: the Mac app makes
  every thumbnail and plays every sound.

  A connection holds a ref from its grant until it releases it or exits, once
  however many times it asked; each holder is monitored once. A held file is
  never removed or rewritten. A file nobody holds stays at least the grace
  period after its last release, so a client that reconnects takes back the
  same path. Beyond that the files are kept within the budget, the least
  recently released removed first. When held and still-kept files alone pass
  the budget, the grant still succeeds, the overage is logged once, and one
  timer, set for the earliest grace to end, brings the files back under the
  budget without another call. The budget and the grace are the protocol's
  numbers (`Protocol.media_budget_bytes/0`, `Protocol.media_release_grace_s/0`).

  The copy is made inside this process, as `MediaStore.materialize_attachment/2`
  makes its own: a blob is at most 20 MiB, and one writer keeps the bookkeeping
  simple. The directory is this process's alone: every regular file in it,
  whatever a crash or the previous run left, is removed at `init/1`, and a
  directory it cannot prepare stops it rather than leaving it half-working.
  """

  use GenServer

  require Logger

  alias FermixChannels.Gateway.MediaDownload
  alias FermixChannels.Mobile.MediaStore
  alias FermixCore.Companion.Protocol
  alias FermixCore.Setup.ConfigStore

  @chunk_bytes 64 * 1_024
  @open_attempts 3
  @sha256 ~r/\A[0-9a-f]{64}\z/
  # Longer than the media store's own call, which a grant waits on before it
  # copies.
  @grant_timeout_ms 15_000

  @type media :: %{
          required(:ref) => String.t(),
          required(:kind) => String.t(),
          required(:mime) => String.t(),
          required(:size_bytes) => non_neg_integer()
        }

  @type blob_fun ::
          (String.t() ->
             {:ok, %{path: String.t(), size_bytes: non_neg_integer()}} | {:error, term()})

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Grant `holder` a managed file holding the bytes of `media.ref` and return
  its absolute path. `media` is the descriptor the timeline row names for the
  ref, already authorised by the caller.
  """
  @spec grant(GenServer.server(), media(), pid()) ::
          {:ok, String.t()} | {:error, :media_missing} | {:error, term()}
  def grant(server, %{ref: ref, kind: kind, mime: mime, size_bytes: size} = media, holder)
      when is_binary(ref) and is_binary(kind) and is_binary(mime) and is_integer(size) and
             size >= 0 and is_pid(holder) do
    descriptor = Map.take(media, [:ref, :kind, :mime, :size_bytes])
    GenServer.call(server, {:grant, descriptor, holder}, @grant_timeout_ms)
  end

  @doc "`holder` has finished with `ref`. Releasing a ref it does not hold changes nothing."
  @spec release(GenServer.server(), String.t(), pid()) :: :ok
  def release(server, ref, holder) when is_binary(ref) and is_pid(holder) do
    GenServer.call(server, {:release, ref, holder})
  end

  @impl true
  def init(opts) do
    with {:ok, config} <- validate_options(opts),
         :ok <- prepare_root(config.root),
         :ok <- clear_root(config.root) do
      {:ok, initial_state(config)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:grant, media, holder}, _from, state), do: grant_file(media, holder, state)

  def handle_call({:release, ref, holder}, _from, state),
    do: {:reply, :ok, release_hold(state, ref, holder)}

  @impl true
  def handle_info({:DOWN, _monitor, :process, holder, _reason}, state),
    do: {:noreply, release_holder(state, holder)}

  def handle_info(:reclaim, state), do: {:noreply, settle_budget(state)}

  def handle_info(message, state) do
    Logger.warning("companion media grants ignored an unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  # -- granting ---------------------------------------------------------------

  defp grant_file(media, holder, state) do
    with :ok <- valid_ref(media.ref),
         {:ok, next} <- ensure_file(media, state) do
      file = Map.fetch!(next.files, media.ref)
      {:reply, {:ok, file.path}, next |> hold(media.ref, holder) |> settle_budget()}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # The same path while the file exists; one that disappeared from outside is
  # made again at its path. The ref is the bytes' digest, so a row naming
  # another size for it no longer matches them.
  defp ensure_file(media, state) do
    case Map.fetch(state.files, media.ref) do
      {:ok, %{size_bytes: size}} when size != media.size_bytes -> {:error, :media_missing}
      {:ok, file} -> reuse_or_remake(file, media, state)
      :error -> make_file(media, target_path(state.root, media), state)
    end
  end

  defp reuse_or_remake(file, media, state) do
    if File.regular?(file.path),
      do: {:ok, state},
      else: make_file(media, file.path, state)
  end

  defp make_file(media, target, state) do
    with {:ok, source} <- stored_blob(media, state.blob),
         {:ok, temp} <- copy_verified(source, media, state.root),
         :ok <- install(temp, target) do
      {:ok, record_file(state, media.ref, target, media.size_bytes)}
    end
  end

  defp target_path(root, media),
    do: Path.join(root, media.ref <> MediaDownload.extension(%{mime_type: media.mime}))

  defp stored_blob(media, blob) do
    case blob.(media.ref) do
      {:ok, %{path: path, size_bytes: size}} when size == media.size_bytes ->
        {:ok, path}

      {:ok, %{size_bytes: size}} ->
        Logger.warning(
          "companion media #{media.ref} is stored as #{size} bytes, " <>
            "not the #{media.size_bytes} its row names"
        )

        {:error, :media_missing}

      {:error, reason} when reason in [:media_gone, :store_not_running] ->
        {:error, :media_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- copying ----------------------------------------------------------------

  defp copy_verified(source, media, root) do
    with {:ok, temp, output} <- open_temp(root, @open_attempts) do
      case fill_temp(source, output, media) do
        :ok -> close_temp(output, temp)
        {:error, reason} -> cleanup_temp_error(output, temp, reason)
      end
    end
  end

  # The store may evict a blob between answering and this open.
  defp fill_temp(source, output, media) do
    case File.open(source, [:read, :binary, :raw]) do
      {:ok, input} ->
        copied = copy_chunks(input, output, media, %{bytes: 0, hash: :crypto.hash_init(:sha256)})
        close_source(input, copied)

      {:error, :enoent} ->
        {:error, :media_missing}

      {:error, reason} ->
        {:error, {:source_open_failed, reason}}
    end
  end

  defp copy_chunks(input, output, media, copied) do
    case :file.read(input, @chunk_bytes) do
      :eof -> verify_copy(media, copied)
      {:ok, data} -> append_chunk(input, output, media, copied, data)
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  # The size the row names bounds the loop: every pass copies at least one
  # byte, and the copy stops before it passes that size.
  defp append_chunk(input, output, media, copied, data) do
    bytes = copied.bytes + byte_size(data)

    if bytes > media.size_bytes do
      mismatch(media, "is longer than the #{media.size_bytes} bytes its row names")
    else
      write_chunk(
        input,
        output,
        media,
        %{bytes: bytes, hash: :crypto.hash_update(copied.hash, data)},
        data
      )
    end
  end

  defp write_chunk(input, output, media, copied, data) do
    case :file.write(output, data) do
      :ok -> copy_chunks(input, output, media, copied)
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp verify_copy(media, copied) do
    digest = copied.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    cond do
      copied.bytes != media.size_bytes ->
        mismatch(media, "is #{copied.bytes} bytes, not the #{media.size_bytes} its row names")

      digest != media.ref ->
        mismatch(media, "no longer hashes to its ref")

      true ->
        :ok
    end
  end

  defp mismatch(media, what) do
    Logger.warning("companion media #{media.ref}: the stored blob #{what}")
    {:error, :media_missing}
  end

  defp close_source(input, copied) do
    case File.close(input) do
      :ok -> copied
      {:error, reason} -> {:error, {:source_close_failed, reason, copied}}
    end
  end

  defp install(temp, target) do
    with :ok <- File.chmod(temp, 0o400),
         :ok <- File.rename(temp, target) do
      :ok
    else
      {:error, reason} -> cleanup_path_error(temp, {:install_failed, reason})
    end
  end

  defp open_temp(_root, 0), do: {:error, :temp_name_exhausted}

  defp open_temp(root, attempts) do
    name = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path = Path.join(root, name <> ".part")

    case File.open(path, [:write, :binary, :exclusive, :raw]) do
      {:ok, io} -> {:ok, path, io}
      {:error, :eexist} -> open_temp(root, attempts - 1)
      {:error, reason} -> {:error, {:temp_open_failed, reason}}
    end
  end

  defp close_temp(output, temp) do
    case File.close(output) do
      :ok -> {:ok, temp}
      {:error, reason} -> cleanup_path_error(temp, {:close_failed, reason})
    end
  end

  defp cleanup_temp_error(io, path, reason) do
    close_result = File.close(io)
    remove_result = remove_file(path)

    case {close_result, remove_result} do
      {:ok, :ok} ->
        {:error, reason}

      {close_error, remove_error} ->
        {:error, {:cleanup_failed, reason, close_error, remove_error}}
    end
  end

  defp cleanup_path_error(path, reason) do
    case remove_file(path) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {:cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # -- holds ------------------------------------------------------------------

  # A remade file keeps the holders it had.
  defp record_file(state, ref, path, size) do
    previous = Map.get(state.files, ref, %{size_bytes: 0, holders: MapSet.new(), released: nil})
    file = %{path: path, size_bytes: size, holders: previous.holders, released: previous.released}

    %{
      state
      | files: Map.put(state.files, ref, file),
        total_bytes: state.total_bytes - previous.size_bytes + size
    }
  end

  defp hold(state, ref, holder) do
    holding =
      Map.get_lazy(state.holders, holder, fn ->
        %{monitor: Process.monitor(holder), refs: MapSet.new()}
      end)

    file = Map.fetch!(state.files, ref)
    held = %{file | holders: MapSet.put(file.holders, holder), released: nil}

    %{
      state
      | files: Map.put(state.files, ref, held),
        holders: Map.put(state.holders, holder, %{holding | refs: MapSet.put(holding.refs, ref)})
    }
  end

  defp release_hold(state, ref, holder) do
    if holds?(state, holder, ref),
      do: state |> let_go(ref, holder) |> forget_idle_holder(holder) |> settle_budget(),
      else: state
  end

  defp release_holder(state, holder) do
    case Map.fetch(state.holders, holder) do
      {:ok, holding} ->
        holding.refs
        |> Enum.reduce(state, &let_go(&2, &1, holder))
        |> forget_idle_holder(holder)
        |> settle_budget()

      :error ->
        state
    end
  end

  defp holds?(state, holder, ref) do
    case Map.fetch(state.holders, holder) do
      {:ok, holding} -> MapSet.member?(holding.refs, ref)
      :error -> false
    end
  end

  # The last holder letting go dates the release; the sequence orders releases
  # read at the same instant.
  defp let_go(state, ref, holder) do
    file = Map.fetch!(state.files, ref)
    holders = MapSet.delete(file.holders, holder)
    released = if MapSet.size(holders) == 0, do: {state.clock.(), state.release_seq}

    %{
      state
      | files: Map.put(state.files, ref, %{file | holders: holders, released: released}),
        holders: Map.update!(state.holders, holder, &%{&1 | refs: MapSet.delete(&1.refs, ref)}),
        release_seq: state.release_seq + 1
    }
  end

  defp forget_idle_holder(state, holder) do
    holding = Map.fetch!(state.holders, holder)

    if MapSet.size(holding.refs) == 0 do
      Process.demonitor(holding.monitor, [:flush])
      %{state | holders: Map.delete(state.holders, holder)}
    else
      state
    end
  end

  # -- the budget -------------------------------------------------------------

  defp settle_budget(state) do
    state
    |> reclaim()
    |> note_overage()
    |> rearm_reclaim()
  end

  # Files nobody holds whose grace has passed go, least recently released
  # first, until the total is within the budget.
  defp reclaim(%{total_bytes: total, budget_bytes: budget} = state) when total <= budget,
    do: state

  defp reclaim(state) do
    now = state.clock.()

    state.files
    |> Enum.filter(fn {_ref, file} -> past_grace?(file, now, state.grace_ms) end)
    |> Enum.sort_by(fn {_ref, file} -> file.released end)
    |> Enum.reduce_while(state, &remove_while_over/2)
  end

  defp past_grace?(%{released: {at, _seq}}, now, grace_ms), do: now - at >= grace_ms
  defp past_grace?(%{released: nil}, _now, _grace_ms), do: false

  defp in_grace?(%{released: {at, _seq}}, now, grace_ms), do: now - at < grace_ms
  defp in_grace?(%{released: nil}, _now, _grace_ms), do: false

  defp remove_while_over(_entry, %{total_bytes: total, budget_bytes: budget} = state)
       when total <= budget,
       do: {:halt, state}

  defp remove_while_over({ref, file}, state), do: {:cont, remove_managed(state, ref, file)}

  # A file that cannot be removed stays counted, and the next pass tries it again.
  defp remove_managed(state, ref, file) do
    case remove_file(file.path) do
      :ok ->
        %{
          state
          | files: Map.delete(state.files, ref),
            total_bytes: state.total_bytes - file.size_bytes
        }

      {:error, reason} ->
        Logger.error("companion media file #{file.path} could not be removed: #{inspect(reason)}")
        state
    end
  end

  # One warning an episode: the flag resets once the total is back within the budget.
  defp note_overage(%{total_bytes: total, budget_bytes: budget} = state) when total <= budget,
    do: %{state | overage_logged: false}

  defp note_overage(%{overage_logged: true} = state), do: state

  defp note_overage(state) do
    held = held_bytes(state.files)

    Logger.warning(
      "companion media in #{state.root} passes its budget: #{held} bytes held and " <>
        "#{state.total_bytes - held} kept after release against #{state.budget_bytes}; " <>
        "every fetch is still granted, and the files go as they are released and their grace ends"
    )

    %{state | overage_logged: true}
  end

  defp held_bytes(files) do
    files
    |> Enum.filter(fn {_ref, file} -> MapSet.size(file.holders) > 0 end)
    |> Enum.reduce(0, fn {_ref, file}, sum -> sum + file.size_bytes end)
  end

  # At most one timer: the one set for the earliest grace to end while the
  # files are over the budget and some are still in their grace.
  defp rearm_reclaim(state) do
    cancel_timer(state.timer)
    %{state | timer: reclaim_timer(state)}
  end

  defp reclaim_timer(%{total_bytes: total, budget_bytes: budget}) when total <= budget, do: nil

  defp reclaim_timer(state) do
    now = state.clock.()

    state.files
    |> Enum.filter(fn {_ref, file} -> in_grace?(file, now, state.grace_ms) end)
    |> Enum.map(fn {_ref, %{released: {at, _seq}}} -> at + state.grace_ms - now end)
    |> Enum.min(fn -> nil end)
    |> start_timer()
  end

  defp start_timer(nil), do: nil
  defp start_timer(delay_ms), do: Process.send_after(self(), :reclaim, delay_ms)

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _remaining = Process.cancel_timer(timer)
    :ok
  end

  # -- start ------------------------------------------------------------------

  defp validate_options(opts) do
    config = %{
      root: Keyword.get_lazy(opts, :root, &default_root/0),
      budget_bytes: Keyword.get_lazy(opts, :budget_bytes, &Protocol.media_budget_bytes/0),
      grace_ms: Keyword.get_lazy(opts, :grace_ms, &default_grace_ms/0),
      clock: Keyword.get(opts, :clock, &monotonic_ms/0),
      blob: Keyword.get(opts, :blob, &store_blob/1)
    }

    with :ok <-
           check(is_binary(config.root) and Path.type(config.root) == :absolute, :invalid_root),
         :ok <-
           check(
             is_integer(config.budget_bytes) and config.budget_bytes > 0,
             :invalid_budget_bytes
           ),
         :ok <- check(is_integer(config.grace_ms) and config.grace_ms >= 0, :invalid_grace_ms),
         :ok <- check(is_function(config.clock, 0), :invalid_clock),
         :ok <- check(is_function(config.blob, 1), :invalid_blob) do
      {:ok, config}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp prepare_root(root) do
    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:directory_failed, root, reason}}
    end
  end

  # Never recursive: a directory or a symlink someone put here is logged and
  # left alone.
  defp clear_root(root) do
    case File.ls(root) do
      {:ok, names} -> names |> Enum.sort() |> Enum.reduce_while(:ok, &clear_entry(root, &1, &2))
      {:error, reason} -> {:error, {:directory_failed, root, reason}}
    end
  end

  defp clear_entry(root, name, :ok) do
    path = Path.join(root, name)

    case File.lstat(path) do
      {:ok, %{type: :regular}} -> clear_file(path)
      {:ok, %{type: type}} -> leave_entry(path, type)
      {:error, :enoent} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:clear_failed, path, reason}}}
    end
  end

  defp clear_file(path) do
    case remove_file(path) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:clear_failed, path, reason}}}
    end
  end

  defp leave_entry(path, type) do
    Logger.warning(
      "companion media directory entry left alone: #{path} is not a regular file (#{type})"
    )

    {:cont, :ok}
  end

  defp initial_state(config) do
    Map.merge(config, %{
      files: %{},
      holders: %{},
      total_bytes: 0,
      release_seq: 0,
      overage_logged: false,
      timer: nil
    })
  end

  defp valid_ref(ref) do
    if Regex.match?(@sha256, ref), do: :ok, else: {:error, {:invalid_field, :ref}}
  end

  defp default_root, do: Path.join(ConfigStore.fermix_home(), "companion/media")

  defp default_grace_ms, do: Protocol.media_release_grace_s() * 1_000

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # The running phone media store. The phone channel turned off stops it, and
  # then there is nothing to grant.
  defp store_blob(ref) do
    case GenServer.whereis(MediaStore) do
      nil -> {:error, :store_not_running}
      store -> fetch_blob(store, ref)
    end
  end

  defp fetch_blob(store, ref) do
    MediaStore.fetch(store, ref)
  catch
    :exit, {:noproc, {GenServer, :call, _args}} -> {:error, :store_not_running}
    :exit, {reason, {GenServer, :call, _args}} -> {:error, {:store_call_failed, reason}}
  end
end
