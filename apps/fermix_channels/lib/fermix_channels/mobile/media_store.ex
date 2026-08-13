defmodule FermixChannels.Mobile.MediaStore do
  @moduledoc """
  Single-writer content-addressed storage for mobile attachments.

  Uploads are written to private temporary files, hashed incrementally, and
  atomically renamed into the SHA-256 namespace only after size and digest
  verification. Durable blobs are never handed to gateway cleanup code;
  `materialize_attachment/2` returns a disposable copy instead.
  """

  use GenServer

  require Logger

  @default_max_media_bytes 20 * 1_024 * 1_024
  @default_max_store_bytes 2 * 1_024 * 1_024 * 1_024
  @manifest_name "attachments.json"
  @manifest_max_bytes 16 * 1_024 * 1_024
  @open_attempts 3
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @type server :: GenServer.server()
  @type upload_spec :: %{
          required(:attach_id) => String.t(),
          required(:kind) => String.t(),
          required(:mime) => String.t(),
          required(:size_bytes) => non_neg_integer(),
          required(:sha256) => String.t(),
          optional(:name) => String.t() | nil
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    root = Keyword.get(opts, :root, default_root())

    %{
      id: {__MODULE__, Keyword.get(opts, :name) || root},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec begin_upload(server(), upload_spec()) ::
          {:ok, :upload | :present} | {:error, term()}
  def begin_upload(server \\ __MODULE__, spec) when is_map(spec) do
    GenServer.call(server, {:begin_upload, spec})
  end

  @spec write_chunk(server(), String.t(), non_neg_integer(), binary()) ::
          :ok | {:error, term()}
  def write_chunk(server \\ __MODULE__, attach_id, index, bytes)
      when is_binary(attach_id) and is_integer(index) and is_binary(bytes) do
    GenServer.call(server, {:write_chunk, attach_id, index, bytes})
  end

  @spec finish_upload(server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def finish_upload(server \\ __MODULE__, attach_id, sha256)
      when is_binary(attach_id) and is_binary(sha256) do
    GenServer.call(server, {:finish_upload, attach_id, String.downcase(sha256)})
  end

  @spec cancel_upload(server(), String.t()) :: :ok | {:error, :unknown_upload}
  def cancel_upload(server \\ __MODULE__, attach_id) when is_binary(attach_id) do
    GenServer.call(server, {:cancel_upload, attach_id})
  end

  @spec put_bytes(server(), binary(), map()) :: {:ok, String.t()} | {:error, term()}
  def put_bytes(server \\ __MODULE__, bytes, metadata \\ %{})
      when is_binary(bytes) and is_map(metadata) do
    GenServer.call(server, {:put_bytes, bytes, metadata})
  end

  @spec fetch(server(), String.t()) :: {:ok, map()} | {:error, :media_gone | term()}
  def fetch(server \\ __MODULE__, ref) when is_binary(ref) do
    GenServer.call(server, {:fetch, String.downcase(ref)})
  end

  @spec attachment(server(), String.t()) :: {:ok, map()} | {:error, :unknown_attachment}
  def attachment(server \\ __MODULE__, attach_id) when is_binary(attach_id) do
    GenServer.call(server, {:attachment, attach_id})
  end

  @spec materialize_attachment(server(), String.t()) :: {:ok, map()} | {:error, term()}
  def materialize_attachment(server \\ __MODULE__, attach_id) when is_binary(attach_id) do
    GenServer.call(server, {:materialize_attachment, attach_id})
  end

  @impl true
  def init(opts) do
    with {:ok, config} <- validate_options(opts),
         :ok <- prepare_directories(config),
         {:ok, blobs, total} <- scan_blobs(config.media_dir),
         {:ok, attachments, rewrite?} <- load_attachment_manifest(config, blobs),
         state <- initial_state(config, blobs, total, attachments),
         :ok <- ensure_attachment_manifest(state, rewrite?) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:begin_upload, spec}, _from, state) do
    with {:ok, upload} <- normalize_upload(spec, state.max_media_bytes),
         :ok <- ensure_new_upload(state, upload.attach_id) do
      begin_valid_upload(upload, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:write_chunk, attach_id, index, bytes}, _from, state) do
    case Map.fetch(state.uploads, attach_id) do
      {:ok, upload} -> write_upload_chunk(upload, index, bytes, state)
      :error -> {:reply, {:error, :unknown_upload}, state}
    end
  end

  def handle_call({:finish_upload, attach_id, digest}, _from, state) do
    case Map.fetch(state.uploads, attach_id) do
      {:ok, upload} -> finish_valid_upload(upload, digest, state)
      :error -> {:reply, {:error, :unknown_upload}, state}
    end
  end

  def handle_call({:cancel_upload, attach_id}, _from, state) do
    case pop_upload(state, attach_id) do
      {:ok, upload, next} ->
        case cleanup_upload(upload) do
          :ok -> {:reply, :ok, next}
          {:error, reason} -> {:reply, {:error, {:cleanup_failed, reason}}, next}
        end

      :error ->
        {:reply, {:error, :unknown_upload}, state}
    end
  end

  def handle_call({:put_bytes, bytes, metadata}, _from, state) do
    put_complete_bytes(bytes, metadata, state)
  end

  def handle_call({:fetch, ref}, _from, state) do
    case existing_blob(state, ref) do
      {:ok, blob} ->
        next = touch_blob(state, ref)
        {:reply, {:ok, Map.merge(blob, %{ref: ref})}, next}

      :error ->
        forget_missing_blob(ref, state)
    end
  end

  def handle_call({:attachment, attach_id}, _from, state) do
    case Map.fetch(state.attachments, attach_id) do
      {:ok, attachment} -> reply_with_live_attachment(attachment, state)
      :error -> {:reply, {:error, :unknown_attachment}, state}
    end
  end

  def handle_call({:materialize_attachment, attach_id}, _from, state) do
    case Map.fetch(state.attachments, attach_id) do
      {:ok, attachment} -> materialize_live_attachment(attachment, state)
      :error -> {:reply, {:error, :unknown_attachment}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.uploads, fn {_id, upload} ->
      case cleanup_upload(upload) do
        :ok -> :ok
        {:error, reason} -> Logger.error("mobile upload cleanup failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp begin_valid_upload(upload, state) do
    case existing_blob(state, upload.sha256) do
      {:ok, _blob} ->
        state
        |> touch_blob(upload.sha256)
        |> persist_completed_attachment(upload, {:ok, :present})

      :error ->
        open_upload(upload, state)
    end
  end

  defp open_upload(upload, state) do
    case make_room(state, upload.size_bytes) do
      {:ok, room} -> open_upload_with_room(upload, room)
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  defp open_upload_with_room(upload, room) do
    case open_unique(room.upload_dir, @open_attempts) do
      {:ok, path, io} ->
        active =
          Map.merge(upload, %{
            path: path,
            io: io,
            next_index: 0,
            written: 0,
            hash: :crypto.hash_init(:sha256)
          })

        {:reply, {:ok, :upload}, put_in(room.uploads[upload.attach_id], active)}

      {:error, reason} ->
        {:reply, {:error, reason}, room}
    end
  end

  defp write_upload_chunk(upload, index, bytes, state) do
    next_size = upload.written + byte_size(bytes)

    cond do
      index != upload.next_index ->
        error = {:unexpected_chunk, expected: upload.next_index, got: index}
        {:reply, {:error, error}, state}

      next_size > upload.size_bytes ->
        fail_upload(upload, {:size_exceeded, next_size, upload.size_bytes}, state)

      true ->
        persist_chunk(upload, bytes, next_size, state)
    end
  end

  defp persist_chunk(upload, bytes, next_size, state) do
    case IO.binwrite(upload.io, bytes) do
      :ok ->
        next_upload = %{
          upload
          | written: next_size,
            next_index: upload.next_index + 1,
            hash: :crypto.hash_update(upload.hash, bytes)
        }

        {:reply, :ok, put_in(state.uploads[upload.attach_id], next_upload)}

      {:error, reason} ->
        fail_upload(upload, {:write_failed, reason}, state)
    end
  end

  defp finish_valid_upload(upload, digest, state) do
    cond do
      not valid_sha256?(digest) ->
        fail_upload(upload, {:invalid_field, :sha256}, state)

      digest != upload.sha256 ->
        fail_upload(upload, {:announced_hash_mismatch, upload.sha256, digest}, state)

      upload.written != upload.size_bytes ->
        fail_upload(upload, {:size_mismatch, upload.size_bytes, upload.written}, state)

      true ->
        verify_and_commit(upload, state)
    end
  end

  defp verify_and_commit(upload, state) do
    actual = upload.hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

    if actual == upload.sha256 do
      commit_upload(upload, state)
    else
      fail_upload(
        upload,
        {:sha256_mismatch, expected: upload.sha256, actual: actual},
        state
      )
    end
  end

  defp commit_upload(upload, state) do
    with :ok <- :file.sync(upload.io),
         :ok <- File.close(upload.io),
         {:ok, committed} <- install_blob(upload.path, upload.sha256, state.media_dir) do
      {_removed, uploads} = Map.pop(state.uploads, upload.attach_id)

      state
      |> Map.put(:uploads, uploads)
      |> record_blob(upload.sha256, upload.size_bytes, committed)
      |> persist_completed_attachment(upload, {:ok, upload.sha256})
    else
      {:error, reason} -> fail_upload(upload, {:commit_failed, reason}, state)
    end
  end

  defp fail_upload(upload, reason, state) do
    {_removed, uploads} = Map.pop(state.uploads, upload.attach_id)
    next = %{state | uploads: uploads}

    case cleanup_upload(upload) do
      :ok ->
        {:reply, {:error, reason}, next}

      {:error, cleanup_reason} ->
        {:reply, {:error, {:cleanup_failed, reason, cleanup_reason}}, next}
    end
  end

  defp put_complete_bytes(bytes, metadata, state) do
    size = byte_size(bytes)
    ref = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    cond do
      size > state.max_media_bytes ->
        {:reply, {:error, {:media_too_large, size, state.max_media_bytes}}, state}

      match?({:ok, _blob}, existing_blob(state, ref)) ->
        {:reply, {:ok, ref}, touch_blob(state, ref)}

      true ->
        persist_complete_bytes(bytes, metadata, ref, state)
    end
  end

  defp persist_complete_bytes(bytes, _metadata, ref, state) do
    case make_room(state, byte_size(bytes)) do
      {:ok, room} -> persist_complete_with_room(bytes, ref, room)
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  defp persist_complete_with_room(bytes, ref, room) do
    with {:ok, temp} <- write_temp_bytes(room.upload_dir, bytes) do
      case install_blob(temp, ref, room.media_dir) do
        {:ok, committed} ->
          next = record_blob(room, ref, byte_size(bytes), committed)
          {:reply, {:ok, ref}, next}

        {:error, reason} ->
          {:reply, cleanup_install_error(temp, reason), room}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, room}
    end
  end

  defp cleanup_install_error(temp, reason) do
    case remove_file(temp) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {:cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp make_room(state, incoming) do
    reserved = Enum.reduce(state.uploads, 0, fn {_id, upload}, acc -> acc + upload.size_bytes end)
    needed = state.total_bytes + reserved + incoming - state.max_store_bytes

    cond do
      incoming > state.max_store_bytes ->
        {:error, {:store_quota_exceeded, incoming}, state}

      needed <= 0 ->
        {:ok, state}

      true ->
        evict_oldest(state, needed)
    end
  end

  defp evict_oldest(state, needed) do
    victims = Enum.sort_by(state.blobs, fn {_ref, blob} -> blob.last_access end)

    Enum.reduce_while(victims, {:ok, state, needed}, &evict_blob/2)
    |> room_result(state.attachments)
  end

  defp evict_blob({ref, blob}, {:ok, state, left}) do
    case File.rm(blob.path) do
      :ok -> continue_eviction(forget_blob(state, ref), blob.size_bytes, left)
      {:error, reason} -> {:halt, {:error, {:eviction_failed, ref, reason}, state}}
    end
  end

  defp continue_eviction(state, removed, left) when removed >= left,
    do: {:halt, {:ok, state, 0}}

  defp continue_eviction(state, removed, left),
    do: {:cont, {:ok, state, left - removed}}

  defp room_result({:ok, state, 0}, previous),
    do: persist_eviction_result({:ok, state}, previous)

  defp room_result({:ok, state, left}, previous),
    do: persist_eviction_result({:error, {:store_quota_exceeded, left}, state}, previous)

  defp room_result({:error, reason, state}, previous),
    do: persist_eviction_result({:error, reason, state}, previous)

  defp install_blob(temp, ref, media_dir) do
    target = Path.join(media_dir, ref)

    case File.stat(target) do
      {:ok, %{type: :regular}} ->
        with :ok <- remove_file(temp) do
          {:ok, target}
        end

      {:error, :enoent} ->
        with :ok <- File.chmod(temp, 0o600),
             :ok <- File.rename(temp, target) do
          {:ok, target}
        end

      {:ok, _stat} ->
        {:error, {:invalid_blob_target, target}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp copy_to_temp(source, dir) do
    with {:ok, path, io} <- open_unique(dir, @open_attempts),
         :ok <- close_temp(io, path) do
      copy_file(source, path)
    else
      {:error, reason} -> {:error, {:materialize_failed, reason}}
    end
  end

  defp write_temp_bytes(dir, bytes) do
    with {:ok, path, io} <- open_unique(dir, @open_attempts) do
      case write_and_close(io, bytes) do
        :ok -> {:ok, path}
        {:error, reason} -> cleanup_temp_error(io, path, reason)
      end
    end
  end

  defp write_and_close(io, bytes) do
    with :ok <- IO.binwrite(io, bytes),
         :ok <- :file.sync(io),
         :ok <- File.close(io) do
      :ok
    end
  end

  defp close_temp(io, path) do
    case File.close(io) do
      :ok -> :ok
      {:error, reason} -> cleanup_path_error(path, {:close_failed, reason})
    end
  end

  defp copy_file(source, path) do
    with {:ok, _bytes} <- File.copy(source, path),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    else
      {:error, reason} -> cleanup_path_error(path, reason)
    end
  end

  defp cleanup_temp_error(io, path, reason) do
    close_result = File.close(io)
    remove_result = remove_file(path)

    case {close_result, remove_result} do
      {result, :ok} when result in [:ok, {:error, :einval}] ->
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

  defp open_unique(_dir, 0), do: {:error, :temp_name_exhausted}

  defp open_unique(dir, attempts) do
    name = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path = Path.join(dir, name <> ".part")

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} -> {:ok, path, io}
      {:error, :eexist} -> open_unique(dir, attempts - 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_upload(spec, max_media_bytes) do
    upload = %{
      attach_id: field(spec, :attach_id),
      kind: field(spec, :kind),
      mime: field(spec, :mime),
      size_bytes: field(spec, :size_bytes),
      sha256: spec |> field(:sha256) |> normalize_digest(),
      name: field(spec, :name)
    }

    with :ok <- nonempty(upload.attach_id, :attach_id),
         :ok <- nonempty(upload.kind, :kind),
         :ok <- nonempty(upload.mime, :mime),
         :ok <- valid_size(upload.size_bytes, max_media_bytes),
         :ok <- valid_digest(upload.sha256),
         :ok <- optional_name(upload.name) do
      {:ok, upload}
    end
  end

  defp validate_options(opts) do
    root = Keyword.get(opts, :root, default_root())
    max_media = Keyword.get(opts, :max_media_bytes, @default_max_media_bytes)
    max_store = Keyword.get(opts, :max_store_bytes, @default_max_store_bytes)

    cond do
      not is_binary(root) or root == "" -> {:error, :invalid_root}
      Path.type(root) != :absolute -> {:error, :root_not_absolute}
      not is_integer(max_media) or max_media <= 0 -> {:error, :invalid_max_media_bytes}
      not is_integer(max_store) or max_store <= 0 -> {:error, :invalid_max_store_bytes}
      true -> {:ok, config(root, max_media, max_store)}
    end
  end

  defp config(root, max_media, max_store) do
    %{
      root: root,
      media_dir: Path.join(root, "media"),
      upload_dir: Path.join(root, "uploads"),
      materialized_dir: Path.join(root, "materialized"),
      manifest_path: Path.join(root, @manifest_name),
      max_media_bytes: max_media,
      max_store_bytes: max_store
    }
  end

  defp initial_state(config, blobs, total, attachments) do
    Map.merge(config, %{
      blobs: blobs,
      total_bytes: total,
      uploads: %{},
      attachments: attachments,
      access_clock: map_size(blobs)
    })
  end

  defp prepare_directories(config) do
    Enum.reduce_while(
      [config.root, config.media_dir, config.upload_dir, config.materialized_dir],
      :ok,
      fn dir, :ok ->
        with :ok <- File.mkdir_p(dir), :ok <- File.chmod(dir, 0o700) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, {:directory_failed, dir, reason}}}
        end
      end
    )
  end

  defp scan_blobs(media_dir) do
    with {:ok, names} <- File.ls(media_dir) do
      names
      |> Enum.sort()
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, %{}, 0}, &scan_blob(media_dir, &1, &2))
    end
  end

  defp scan_blob(media_dir, {name, access}, {:ok, blobs, total}) do
    path = Path.join(media_dir, name)

    case {valid_sha256?(name), File.stat(path)} do
      {true, {:ok, %{type: :regular, size: size, mode: mode}}}
      when Bitwise.band(mode, 0o077) == 0 ->
        blob = %{path: path, size_bytes: size, last_access: access}
        {:cont, {:ok, Map.put(blobs, name, blob), total + size}}

      _other ->
        {:halt, {:error, {:invalid_media_entry, path}}}
    end
  end

  defp load_attachment_manifest(config, blobs) do
    case File.stat(config.manifest_path) do
      {:error, :enoent} ->
        {:ok, %{}, true}

      {:ok, stat} ->
        load_existing_manifest(config.manifest_path, stat, blobs)

      {:error, reason} ->
        {:error, {:attachment_manifest_stat_failed, reason}}
    end
  end

  defp load_existing_manifest(path, %{type: :regular, mode: mode, size: size}, blobs) do
    permissions = Bitwise.band(mode, 0o777)

    cond do
      permissions != 0o600 ->
        {:error, {:insecure_attachment_manifest, path, permissions}}

      size > @manifest_max_bytes ->
        {:error, {:attachment_manifest_too_large, size, @manifest_max_bytes}}

      true ->
        decode_attachment_manifest(path, blobs)
    end
  end

  defp load_existing_manifest(path, _stat, _blobs),
    do: {:error, {:invalid_attachment_manifest_target, path}}

  defp decode_attachment_manifest(path, blobs) do
    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- Jason.decode(bytes),
         {:ok, attachments} <- validate_attachment_manifest(decoded) do
      live =
        Map.filter(attachments, fn {_id, attachment} -> Map.has_key?(blobs, attachment.ref) end)

      {:ok, live, map_size(live) != map_size(attachments)}
    else
      {:error, reason} -> {:error, {:invalid_attachment_manifest, reason}}
    end
  end

  defp validate_attachment_manifest(%{"version" => 1, "attachments" => entries})
       when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, &accumulate_attachment/2)
  end

  defp validate_attachment_manifest(_decoded), do: {:error, :invalid_shape}

  defp accumulate_attachment(entry, {:ok, attachments}) do
    case validate_attachment_entry(entry) do
      {:ok, attachment} -> add_attachment(attachment, attachments)
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp add_attachment(attachment, attachments) do
    if Map.has_key?(attachments, attachment.attach_id) do
      {:halt, {:error, {:duplicate_attach_id, attachment.attach_id}}}
    else
      {:cont, {:ok, Map.put(attachments, attachment.attach_id, attachment)}}
    end
  end

  defp validate_attachment_entry(entry) when is_map(entry) do
    attachment = %{
      attach_id: Map.get(entry, "attach_id"),
      ref: Map.get(entry, "ref"),
      kind: Map.get(entry, "kind"),
      mime_type: Map.get(entry, "mime_type"),
      file_name: Map.get(entry, "file_name"),
      size_bytes: Map.get(entry, "size_bytes")
    }

    with :ok <- nonempty(attachment.attach_id, :attach_id),
         :ok <- valid_digest(attachment.ref),
         :ok <- nonempty(attachment.kind, :kind),
         :ok <- nonempty(attachment.mime_type, :mime_type),
         :ok <- manifest_size(attachment.size_bytes),
         :ok <- optional_name(attachment.file_name) do
      {:ok, attachment}
    end
  end

  defp validate_attachment_entry(_entry), do: {:error, :invalid_entry}

  defp manifest_size(value) when is_integer(value) and value >= 0, do: :ok
  defp manifest_size(_value), do: {:error, {:invalid_field, :size_bytes}}

  defp completed_attachment(upload) do
    %{
      attach_id: upload.attach_id,
      ref: upload.sha256,
      kind: upload.kind,
      mime_type: upload.mime,
      file_name: upload.name,
      size_bytes: upload.size_bytes
    }
  end

  defp ensure_attachment_manifest(_state, false), do: :ok
  defp ensure_attachment_manifest(state, true), do: persist_attachment_manifest(state)

  defp persist_completed_attachment(state, upload, success_reply) do
    attachment = completed_attachment(upload)
    next = put_in(state.attachments[upload.attach_id], attachment)

    case persist_attachment_manifest(next) do
      :ok -> {:reply, success_reply, next}
      {:error, reason} -> {:reply, {:error, {:manifest_write_failed, reason}}, state}
    end
  end

  defp persist_attachment_manifest(state) do
    payload = %{
      "version" => 1,
      "attachments" =>
        state.attachments
        |> Map.values()
        |> Enum.sort_by(& &1.attach_id)
    }

    with {:ok, encoded} <- Jason.encode(payload),
         {:ok, temp, io} <- open_manifest_temp(state.root, @open_attempts),
         :ok <- write_manifest_temp(io, temp, encoded),
         :ok <- replace_manifest(temp, state.manifest_path) do
      :ok
    end
  end

  defp open_manifest_temp(_root, 0), do: {:error, :manifest_temp_name_exhausted}

  defp open_manifest_temp(root, attempts) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    path = Path.join(root, "attachments-#{suffix}.part")

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        case File.chmod(path, 0o600) do
          :ok -> {:ok, path, io}
          {:error, reason} -> cleanup_manifest_open(io, path, reason)
        end

      {:error, :eexist} ->
        open_manifest_temp(root, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_manifest_open(io, path, reason) do
    _close_result = File.close(io)

    case remove_file(path) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, {:cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp write_manifest_temp(io, path, bytes) do
    case write_and_close(io, bytes) do
      :ok -> :ok
      {:error, reason} -> cleanup_path_error(path, reason)
    end
  end

  defp replace_manifest(temp, target) do
    case File.rename(temp, target) do
      :ok -> :ok
      {:error, reason} -> cleanup_path_error(temp, reason)
    end
  end

  defp reply_with_live_attachment(attachment, state) do
    case existing_blob(state, attachment.ref) do
      {:ok, _blob} -> {:reply, {:ok, attachment}, state}
      :error -> invalidate_missing_attachment(attachment.ref, state)
    end
  end

  defp materialize_live_attachment(attachment, state) do
    case existing_blob(state, attachment.ref) do
      {:ok, blob} -> copy_live_attachment(attachment, blob, state)
      :error -> invalidate_missing_attachment(attachment.ref, state)
    end
  end

  defp copy_live_attachment(attachment, blob, state) do
    case copy_to_temp(blob.path, state.materialized_dir) do
      {:ok, temp_path} ->
        next = touch_blob(state, attachment.ref)
        {:reply, {:ok, Map.put(attachment, :path, temp_path)}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp invalidate_missing_attachment(ref, state) do
    next = forget_blob(state, ref)

    case persist_attachment_manifest(next) do
      :ok -> {:reply, {:error, :unknown_attachment}, next}
      {:error, reason} -> {:reply, {:error, {:manifest_write_failed, reason}}, next}
    end
  end

  defp forget_missing_blob(ref, state) do
    next = forget_blob(state, ref)

    case persist_changed_attachments(state, next) do
      :ok -> {:reply, {:error, :media_gone}, next}
      {:error, reason} -> {:reply, {:error, {:manifest_write_failed, reason}}, next}
    end
  end

  defp persist_changed_attachments(previous, next) do
    if previous.attachments == next.attachments,
      do: :ok,
      else: persist_attachment_manifest(next)
  end

  defp persist_eviction_result(result, previous_attachments) do
    state = elem(result, tuple_size(result) - 1)

    if state.attachments == previous_attachments do
      normalize_room_result(result)
    else
      case persist_attachment_manifest(state) do
        :ok -> normalize_room_result(result)
        {:error, reason} -> {:error, {:manifest_write_failed, reason}, state}
      end
    end
  end

  defp normalize_room_result({:ok, state}), do: {:ok, state}
  defp normalize_room_result({:error, reason, state}), do: {:error, reason, state}

  defp record_blob(state, ref, size, path) do
    clock = state.access_clock + 1
    already = get_in(state, [:blobs, ref, :size_bytes]) || 0
    blob = %{path: path, size_bytes: size, last_access: clock}

    state
    |> put_in([:blobs, ref], blob)
    |> Map.put(:total_bytes, state.total_bytes - already + size)
    |> Map.put(:access_clock, clock)
  end

  defp touch_blob(state, ref) do
    case Map.fetch(state.blobs, ref) do
      {:ok, blob} ->
        clock = state.access_clock + 1

        state
        |> put_in([:blobs, ref], %{blob | last_access: clock})
        |> Map.put(:access_clock, clock)

      :error ->
        state
    end
  end

  defp forget_blob(state, ref) do
    attachments =
      Map.reject(state.attachments, fn {_attach_id, attachment} -> attachment.ref == ref end)

    case Map.pop(state.blobs, ref) do
      {nil, _blobs} ->
        %{state | attachments: attachments}

      {blob, blobs} ->
        %{
          state
          | blobs: blobs,
            attachments: attachments,
            total_bytes: state.total_bytes - blob.size_bytes
        }
    end
  end

  defp existing_blob(state, ref) do
    with {:ok, blob} <- Map.fetch(state.blobs, ref),
         {:ok, %{type: :regular}} <- File.stat(blob.path) do
      {:ok, blob}
    else
      _error -> :error
    end
  end

  defp pop_upload(state, attach_id) do
    case Map.pop(state.uploads, attach_id) do
      {nil, _uploads} -> :error
      {upload, uploads} -> {:ok, upload, %{state | uploads: uploads}}
    end
  end

  defp cleanup_upload(upload) do
    close_result = File.close(upload.io)
    remove_result = remove_file(upload.path)

    case {close_result, remove_result} do
      {result, :ok} when result in [:ok, {:error, :einval}] -> :ok
      {close_error, remove_error} -> {:error, {close_error, remove_error}}
    end
  end

  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_new_upload(state, id) do
    cond do
      Map.has_key?(state.uploads, id) -> {:error, :upload_exists}
      Map.has_key?(state.attachments, id) -> {:error, :attachment_exists}
      true -> :ok
    end
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp normalize_digest(value) when is_binary(value), do: String.downcase(value)
  defp normalize_digest(value), do: value

  defp nonempty(value, _field)
       when is_binary(value) and byte_size(value) in 1..255,
       do: :ok

  defp nonempty(_value, field), do: {:error, {:invalid_field, field}}

  defp valid_size(value, max) when is_integer(value) and value >= 0 and value <= max, do: :ok

  defp valid_size(value, max) when is_integer(value) and value > max,
    do: {:error, {:media_too_large, value, max}}

  defp valid_size(_value, _max), do: {:error, {:invalid_field, :size_bytes}}

  defp valid_digest(value),
    do: if(valid_sha256?(value), do: :ok, else: {:error, {:invalid_field, :sha256}})

  defp valid_sha256?(value) when is_binary(value), do: Regex.match?(@sha256, value)
  defp valid_sha256?(_value), do: false
  defp optional_name(nil), do: :ok
  defp optional_name(value) when is_binary(value) and byte_size(value) in 1..255, do: :ok
  defp optional_name(_value), do: {:error, {:invalid_field, :name}}

  defp default_root do
    Path.join(System.get_env("FERMIX_HOME") || Path.expand("~/.fermix"), "mobile")
  end
end
