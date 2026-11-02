defmodule FermixChannels.Companion.Inbox do
  @moduledoc """
  The one owner of the attachment inbox (companion protocol 7):
  `<FERMIX_HOME>/companion/inbox`, where the Mac app hands the daemon a file
  it attaches in the chat.

  The Mac and the daemon share a file system, so a file crosses by path
  rather than in chunks: the app writes `<dir>/<attach_id>` (mode `0600`) and
  sends `attach_file`; the connection asks here, and this process reads the
  file into the media store the phone's uploads use
  (`Mobile.MediaStore.import_file/3`, the same limits and the same size and
  digest verification), under the same `attach_id`, so the `msg` that names
  it reaches its turn as a phone's does. Then it removes the file, whatever
  came of it, before the connection answers: once the app reads the answer
  the name is free again, and the app never deletes anything here.

  It makes the directory at `0700` and empties it when it starts, which also
  clears what a crash or the previous run left. Only regular files and
  symlinks are removed, never recursively and never through a link; a
  directory someone put here is logged and left alone. A directory it cannot
  prepare stops it, as `Companion.MediaGrants` does. Imports run one at a
  time in this process, which owns each upload while it runs.

  `offer/1` is what a `server_hello` tells the owner's connection: the
  directory and the largest file the store takes, only while the store runs.
  `discard/2` removes a file whose `attach_file` was refused before it was
  read (a connection not placed as the owner's, an engine in the device
  role). `describe_error/1` is the engine's sentence for every refusal, for
  the `error` that answers a refused `attach_file`.
  """

  use GenServer

  require Logger

  alias FermixChannels.Mobile.MediaStore
  alias FermixCore.Companion.Protocol
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Text

  # Longer than the store's own calls, which an import makes one per chunk.
  # Every call waits its turn behind an import, a hello's offer included, so
  # each has this bound.
  @call_timeout_ms 30_000
  @max_message_bytes 512

  @type offer :: %{required(String.t()) => String.t() | pos_integer()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "The inbox under the Fermix home: `<FERMIX_HOME>/companion/inbox`."
  @spec default_dir() :: String.t()
  def default_dir, do: Path.join(ConfigStore.fermix_home(), "companion/inbox")

  @doc """
  What a `server_hello` tells the owner's connection, string keyed as it
  travels: `dir`, the inbox's absolute path, and `max_bytes`, the largest
  file the store takes. `{:error, :store_not_running}` while no store runs,
  and the hello then offers no attachments.
  """
  @spec offer(GenServer.server()) :: {:ok, offer()} | {:error, :store_not_running}
  def offer(server) when not is_nil(server), do: GenServer.call(server, :offer, @call_timeout_ms)

  @doc """
  Read `<dir>/<attach_id>` into the media store under `attachment` (the
  `attach_file` payload: `attach_id`, `kind`, `mime`, `size_bytes`, `sha256`,
  `name?`), then remove the file, whatever came of it.
  """
  @spec take(GenServer.server(), map()) :: {:ok, :present} | {:error, term()}
  def take(server, %{"attach_id" => attach_id} = attachment) when is_binary(attach_id),
    do: GenServer.call(server, {:take, attachment}, @call_timeout_ms)

  @doc """
  Remove `<dir>/<attach_id>` unread: the answer to an `attach_file` refused
  before anything was read.
  """
  @spec discard(GenServer.server(), String.t()) :: :ok
  def discard(server, attach_id) when is_binary(attach_id),
    do: GenServer.call(server, {:discard, attach_id}, @call_timeout_ms)

  @doc """
  The engine's sentence for why an `attach_file` was refused, at most 512
  bytes, in the words a person reads in the chat.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(reason), do: reason |> sentence() |> Text.truncate_utf8(@max_message_bytes)

  defp sentence(:not_owner), do: "Only the owner's own Fermix app can attach files."

  defp sentence(:no_inbox),
    do: "Files cannot be attached from this computer while Fermix runs on another one."

  defp sentence(:store_not_running), do: "Fermix cannot take files right now. Try again later."
  defp sentence(:file_missing), do: "Fermix found no file to take. Attach it again."

  defp sentence({:not_regular_file, _type}),
    do: "Fermix takes only a plain file the app saved for it. Attach it again."

  defp sentence({:media_too_large, _size, max}),
    do: "This file is too large: Fermix takes files of up to #{size_words(max)}."

  defp sentence({:store_quota_exceeded, _bytes}),
    do: "Fermix has no room for this file right now. Try a smaller one."

  defp sentence(reason) when reason in [:upload_limit_reached, :store_upload_limit_reached],
    do: "Fermix is already taking in as many files as it can. Try again in a moment."

  defp sentence(reason) when reason in [:upload_exists, :attachment_exists],
    do: "Fermix already has a file under this name. Attach it again."

  defp sentence({mismatch, _expected, _actual})
       when mismatch in [:size_exceeded, :size_mismatch, :announced_hash_mismatch],
       do: changed_file()

  defp sentence({:sha256_mismatch, _digests}), do: changed_file()
  defp sentence({:file_unreadable, _reason}), do: "Fermix could not read this file."
  defp sentence({:read_failed, _reason}), do: "Fermix could not read this file."
  defp sentence(_failure), do: "Fermix could not store this file."

  defp changed_file, do: "This file changed before Fermix could read it. Attach it again."

  # The store's bound in words: whole mebibytes as MB, whole kibibytes as KB,
  # anything else in bytes.
  defp size_words(bytes) when rem(bytes, 1_048_576) == 0, do: "#{div(bytes, 1_048_576)} MB"
  defp size_words(bytes) when rem(bytes, 1_024) == 0, do: "#{div(bytes, 1_024)} KB"
  defp size_words(bytes), do: "#{bytes} bytes"

  @impl true
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &default_dir/0)
    store = Keyword.get(opts, :store, MediaStore)

    with :ok <- valid_dir(dir),
         :ok <- prepare(dir),
         :ok <- empty(dir) do
      {:ok, %{dir: dir, store: store}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:offer, _from, state), do: {:reply, offer_from(state), state}

  def handle_call({:take, attachment}, _from, state),
    do: {:reply, take_file(attachment, state), state}

  def handle_call({:discard, attach_id}, _from, state) do
    :ok = remove_named(attach_id, state)
    {:reply, :ok, state}
  end

  defp offer_from(state) do
    case store_limit(state.store) do
      {:ok, max_bytes} -> {:ok, %{"dir" => state.dir, "max_bytes" => max_bytes}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The running media store. A store whose manifest cannot be read never
  # starts (`MediaStore.start_admitted/1`), and then there is nowhere to put
  # a file.
  defp store_limit(store) do
    case GenServer.whereis(store) do
      nil -> {:error, :store_not_running}
      _pid -> {:ok, MediaStore.max_media_bytes(store)}
    end
  catch
    :exit, {:noproc, {GenServer, :call, _args}} -> {:error, :store_not_running}
  end

  defp take_file(%{"attach_id" => attach_id} = attachment, state) do
    taken = import_attachment(attachment, state)
    :ok = remove_named(attach_id, state)
    taken
  end

  # A store that stops mid-import is not running; any other exit of its calls
  # stops this process, and the store's monitor of the upload's owner then
  # ends the upload, so nothing is left half-taken.
  defp import_attachment(%{"attach_id" => attach_id} = attachment, state) do
    with :ok <- valid_attach_id(attach_id),
         :ok <- store_running(state.store) do
      MediaStore.import_file(state.store, Path.join(state.dir, attach_id), spec(attachment))
    end
  catch
    :exit, {:noproc, {GenServer, :call, _args}} -> {:error, :store_not_running}
  end

  defp store_running(store) do
    if GenServer.whereis(store), do: :ok, else: {:error, :store_not_running}
  end

  defp spec(attachment) do
    %{
      attach_id: attachment["attach_id"],
      kind: attachment["kind"],
      mime: attachment["mime"],
      size_bytes: attachment["size_bytes"],
      sha256: attachment["sha256"],
      name: attachment["name"]
    }
  end

  # The name is the wire's attach id, a file name and never a path: the codec
  # refuses any other before it reaches here, and it is checked again before
  # it is joined to the inbox.
  defp valid_attach_id(attach_id) do
    if Protocol.attach_id?(attach_id),
      do: :ok,
      else: {:error, {:invalid_field, :attach_id}}
  end

  defp remove_named(attach_id, state) do
    case valid_attach_id(attach_id) do
      :ok -> remove_entry(Path.join(state.dir, attach_id))
      {:error, _invalid} -> :ok
    end
  end

  # A removal that fails is logged and the file left for the next start; the
  # answer to the client does not depend on it.
  defp remove_entry(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> log_left(path, reason)
    end
  end

  defp log_left(path, reason) do
    Logger.error("companion inbox could not remove #{path}: #{inspect(reason)}")
    :ok
  end

  # -- start ------------------------------------------------------------------

  defp valid_dir(dir) do
    if is_binary(dir) and Path.type(dir) == :absolute,
      do: :ok,
      else: {:error, {:invalid_dir, dir}}
  end

  defp prepare(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:directory_failed, dir, reason}}
    end
  end

  # Never recursive: a directory someone put here is logged and left alone.
  defp empty(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.sort() |> Enum.reduce_while(:ok, &empty_entry(dir, &1, &2))
      {:error, reason} -> {:error, {:directory_failed, dir, reason}}
    end
  end

  defp empty_entry(dir, name, :ok) do
    path = Path.join(dir, name)

    case File.lstat(path) do
      {:ok, %{type: type}} when type in [:regular, :symlink] -> clear_file(path)
      {:ok, %{type: type}} -> leave_entry(path, type)
      {:error, :enoent} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:clear_failed, path, reason}}}
    end
  end

  defp clear_file(path) do
    case File.rm(path) do
      :ok -> {:cont, :ok}
      {:error, :enoent} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:clear_failed, path, reason}}}
    end
  end

  defp leave_entry(path, type) do
    Logger.warning("companion inbox entry left alone: #{path} is not a file (#{type})")
    {:cont, :ok}
  end
end
