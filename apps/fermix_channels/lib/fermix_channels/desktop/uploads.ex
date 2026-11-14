defmodule FermixChannels.Desktop.Uploads do
  @moduledoc """
  The files this computer's app attaches in its chat, carried to the server
  (M97 §9.3, D22).

  After a move the app's chat is the server's (`Desktop.Tunnel`), but the
  app writes the files it attaches on this computer. So the device engine
  keeps an inbox of its own, as a primary does: `<FERMIX_HOME>/companion/inbox`
  (`0700`, emptied when it starts, `Companion.Inbox.prepare_dir/1`), which
  the tunnel offers the app in the server's `server_hello` (`offer/1`: the
  directory, and the server's own bound on a file), so the attach button is
  the same and the app changes nothing. Each `attach_file` the app sends is
  taken here (`take/3`), never passed to the server:

    1. the file is read from the inbox (a regular file, never a link), held
       to the server's bound, the size the app announced and its SHA-256,
       and removed, whatever came of it, before the answer;
    2. it goes to the server with the phone's chunked upload over this
       computer's desktop session, in the bulk lane (`Desktop.Relay`):
       `attach_begin` with the SHA-256 first, so a file the server already
       holds is never sent again, then `attach_chunk`s of 60 KiB from index 0
       and `attach_end`, each written before the next;
    3. the tunnel is told `{:upload_done, attach_id, :present}` once the
       server answered `attach_status` `present`, or `{:upload_done,
       attach_id, {:error, sentence}}`, in `Companion.Inbox`'s words where
       the reason is the same as on a primary.

  One upload runs at a time, in a process of its own, so this server keeps
  answering while a file streams: the server's answers to an upload name no
  upload when they refuse one, so one at a time is what makes them its. At
  most 8 wait behind it; past that a file is refused as a primary refuses
  one past its upload bound. Each answer is waited for 30 s.

  The relay hands this process the server's answers (`handle/3`) and the
  session's end (`link_down/2`), which fails the running upload with the
  relay's sentence. A move back to this computer drops every upload waiting
  or running (`drop_all/2`), each told why with its file's name.
  """

  use GenServer

  require Logger

  alias FermixChannels.Companion.Inbox
  alias FermixChannels.Desktop.Relay
  alias FermixCore.Companion.Protocol
  alias FermixCore.Text

  @chunk_bytes 60 * 1_024
  @answer_ms 30_000
  @max_waiting 8
  @max_message_bytes 512
  @not_taken_sentence "Your server runs an older Fermix that takes no files from this computer. " <>
                        "It updates itself; attach the file again once it has."
  @busy_sentence "The link to your server is too busy to carry this file now. " <>
                   "Try again in a moment."
  @timed_out_sentence "Your server did not take this file in time. Attach it again."
  @failed_sentence "Fermix could not send this file to your server. Attach it again."

  @typedoc "What the tunnel is told of one upload."
  @type outcome :: :present | {:error, String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  What the tunnel adds to the server's `server_hello` for the app (companion
  protocol 7's `attachments`): this inbox and the server's bound on a file,
  while a session is up whose server takes a computer's uploads; otherwise
  why not, and the app is offered no attachments.
  """
  @spec offer(GenServer.server()) ::
          {:ok, %{String.t() => String.t() | pos_integer()}} | {:error, term()}
  def offer(server \\ __MODULE__) do
    GenServer.call(server, :offer, @answer_ms)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown, :timeout] ->
      {:error, :not_running}
  end

  @doc """
  Takes the file the app wrote at `<inbox>/<attach_id>` for `attachment`
  (the `attach_file` payload) and sends it to the server; `reply_to` is told
  `{:upload_done, attach_id, outcome}`.
  """
  @spec take(GenServer.server(), map(), pid()) :: :ok
  def take(server \\ __MODULE__, %{"attach_id" => attach_id} = attachment, reply_to)
      when is_binary(attach_id) and is_pid(reply_to),
      do: GenServer.cast(server, {:take, attachment, reply_to})

  @doc "One of the server's answers to an upload (`attach_status`, or an `error`), from the relay."
  @spec handle(GenServer.server(), String.t(), map()) :: :ok
  def handle(server, type, fields) when type in ["attach_status", "error"] and is_map(fields),
    do: GenServer.cast(server, {:answer, type, fields})

  @doc "The session ended: the upload running fails with the relay's `sentence`."
  @spec link_down(GenServer.server(), String.t()) :: :ok
  def link_down(server, sentence) when is_binary(sentence),
    do: GenServer.cast(server, {:link_down, sentence})

  @doc """
  Drops every upload waiting or running, each tunnel told `"<file> was not
  sent: <why>"`, `why` the caller's sentence (a move back to this computer).
  Answers once each was told.
  """
  @spec drop_all(GenServer.server(), String.t()) :: :ok
  def drop_all(server \\ __MODULE__, why) when is_binary(why) do
    GenServer.call(server, {:drop_all, why}, @answer_ms)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> :ok
  end

  # -- the process --------------------------------------------------------------

  @impl true
  def init(opts) do
    dir = Keyword.get_lazy(opts, :dir, &Inbox.default_dir/0)

    case Inbox.prepare_dir(dir) do
      :ok ->
        {:ok,
         %{
           dir: dir,
           relay: Keyword.get(opts, :relay, Relay),
           answer_ms: Keyword.get(opts, :answer_ms, @answer_ms),
           waiting: :queue.new(),
           running: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:offer, _from, state) do
    case Relay.upload_bound(state.relay) do
      {:ok, max_bytes} -> {:reply, {:ok, %{"dir" => state.dir, "max_bytes" => max_bytes}}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:drop_all, why}, _from, state) do
    {running, state} = take_running(state)

    for {attachment, reply_to} <- running ++ :queue.to_list(state.waiting) do
      :ok = remove(state.dir, attachment["attach_id"])
      done(reply_to, attachment, {:error, not_sent(attachment, why)})
    end

    {:reply, :ok, %{state | waiting: :queue.new()}}
  end

  @impl true
  def handle_cast({:take, attachment, reply_to}, state) do
    if :queue.len(state.waiting) >= @max_waiting do
      :ok = remove(state.dir, attachment["attach_id"])
      done(reply_to, attachment, {:error, Inbox.describe_error(:upload_limit_reached)})
      {:noreply, state}
    else
      {:noreply, next(%{state | waiting: :queue.in({attachment, reply_to}, state.waiting)})}
    end
  end

  # An answer with no upload running is no upload's: the relay hands this
  # process every refusal that could be one, so it is said here, as the
  # relay says any other refusal of the server's.
  def handle_cast({:answer, type, fields}, %{running: nil} = state) do
    Logger.warning(
      "desktop uploads: the server sent #{type} with no upload running: " <>
        "#{fields["code"] || fields["status"]}: #{fields["message"]}"
    )

    {:noreply, state}
  end

  def handle_cast({:answer, type, fields}, state),
    do: {:noreply, to_running(state, {:upload_answer, type, fields})}

  def handle_cast({:link_down, sentence}, state),
    do: {:noreply, to_running(state, {:upload_link_down, sentence})}

  @impl true
  def handle_info({:upload_result, pid, outcome}, %{running: %{pid: pid} = running} = state) do
    Process.demonitor(running.monitor, [:flush])
    done(running.reply_to, running.attachment, outcome)
    {:noreply, next(%{state | running: nil})}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{running: %{monitor: monitor}} = state
      ) do
    Logger.error("desktop uploads: an upload ended without an answer: #{inspect(reason)}")
    done(state.running.reply_to, state.running.attachment, {:error, @failed_sentence})
    {:noreply, next(%{state | running: nil})}
  end

  def handle_info(message, state) do
    Logger.debug("desktop uploads ignored #{inspect(message, limit: 5)}")
    {:noreply, state}
  end

  # -- running one ------------------------------------------------------------------

  defp next(%{running: nil} = state) do
    case :queue.out(state.waiting) do
      {{:value, {attachment, reply_to}}, waiting} ->
        run(attachment, reply_to, %{state | waiting: waiting})

      {:empty, _waiting} ->
        state
    end
  end

  defp next(state), do: state

  defp run(attachment, reply_to, state) do
    server = self()
    context = Map.take(state, [:dir, :relay, :answer_ms])

    {pid, monitor} =
      spawn_monitor(fn -> send(server, {:upload_result, self(), upload(attachment, context)}) end)

    %{state | running: %{pid: pid, monitor: monitor, attachment: attachment, reply_to: reply_to}}
  end

  defp to_running(%{running: %{pid: pid}} = state, message) do
    send(pid, message)
    state
  end

  defp to_running(state, _message), do: state

  # The upload a move back drops goes with the others, after its process.
  defp take_running(%{running: nil} = state), do: {[], state}

  defp take_running(%{running: running} = state) do
    Process.demonitor(running.monitor, [:flush])
    Process.exit(running.pid, :kill)
    {[{running.attachment, running.reply_to}], %{state | running: nil}}
  end

  defp done(reply_to, %{"attach_id" => attach_id}, outcome) do
    send(reply_to, {:upload_done, attach_id, outcome})
    :ok
  end

  defp not_sent(attachment, why) do
    name = attachment["name"] || "This file"
    Text.truncate_utf8("#{name} was not sent: #{why}", @max_message_bytes)
  end

  # -- one upload, in its own process ---------------------------------------------------

  @doc false
  # Runs in the upload's process: the file read and removed, then the
  # server's upload; the outcome is what the tunnel is told.
  @spec upload(map(), map()) :: outcome()
  def upload(%{"attach_id" => attach_id} = attachment, context) do
    read = read(attachment, context)
    :ok = remove(context.dir, attach_id)

    case send_file(read, attachment, context) do
      :present -> :present
      {:error, reason} -> {:error, sentence(reason, attachment, read)}
    end
  end

  defp send_file({:ok, bytes, _max}, attachment, context) do
    with :ok <- send_begin(attachment, context),
         {:ok, status} <- await_status(attachment, context) do
      stream(status, bytes, attachment, context)
    end
  end

  defp send_file({:error, reason}, _attachment, _context), do: {:error, reason}

  defp read(%{"attach_id" => attach_id} = attachment, context) do
    path = Path.join(context.dir, attach_id)

    with :ok <- valid_id(attach_id),
         {:ok, max} <- Relay.upload_bound(context.relay),
         {:ok, size} <- regular_size(path),
         :ok <- within(size, max),
         :ok <- announced_size(attachment, size),
         {:ok, bytes} <- read_bytes(path),
         :ok <- announced_digest(attachment, bytes) do
      {:ok, bytes, max}
    end
  end

  defp valid_id(attach_id) do
    if Protocol.attach_id?(attach_id), do: :ok, else: {:error, {:invalid_field, :attach_id}}
  end

  defp regular_size(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} -> {:ok, size}
      {:ok, %{type: type}} -> {:error, {:not_regular_file, type}}
      {:error, :enoent} -> {:error, :file_missing}
      {:error, reason} -> {:error, {:file_unreadable, reason}}
    end
  end

  defp within(size, max) when size <= max, do: :ok
  defp within(size, max), do: {:error, {:media_too_large, size, max}}

  defp announced_size(%{"size_bytes" => size}, size), do: :ok

  defp announced_size(%{"size_bytes" => announced}, size),
    do: {:error, {:size_mismatch, announced, size}}

  defp read_bytes(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:file_unreadable, reason}}
    end
  end

  defp announced_digest(%{"sha256" => announced}, bytes) do
    digest = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    if digest == announced, do: :ok, else: {:error, {:sha256_mismatch, {announced, digest}}}
  end

  defp send_begin(attachment, context) do
    begin =
      attachment
      |> Map.take(~w(attach_id kind mime size_bytes sha256 name))
      |> Map.put("t", "attach_begin")

    relayed(Relay.send_event(context.relay, begin))
  end

  defp stream("present", _bytes, _attachment, _context), do: :present

  defp stream("upload", bytes, %{"attach_id" => attach_id} = attachment, context) do
    with :ok <- chunks(bytes, attach_id, 0, context),
         :ok <- relayed(Relay.send_event(context.relay, end_event(attachment))),
         {:ok, "present"} <- await_status(attachment, context) do
      :present
    else
      {:ok, other} -> {:error, {:unexpected_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream(other, _bytes, _attachment, _context), do: {:error, {:unexpected_status, other}}

  # One frame at a time, each written before the next (`send_event/3`
  # answers once its frame is written), so a file never queues whole.
  defp chunks(<<>>, _attach_id, _index, _context), do: :ok

  defp chunks(bytes, attach_id, index, context) do
    size = min(byte_size(bytes), @chunk_bytes)
    <<chunk::binary-size(size), rest::binary>> = bytes
    event = %{"t" => "attach_chunk", "attach_id" => attach_id, "index" => index}

    case relayed(Relay.send_event(context.relay, event, chunk)) do
      :ok -> chunks(rest, attach_id, index + 1, context)
      {:error, reason} -> {:error, reason}
    end
  end

  defp end_event(attachment),
    do: %{
      "t" => "attach_end",
      "attach_id" => attachment["attach_id"],
      "sha256" => attachment["sha256"]
    }

  defp relayed(:ok), do: :ok
  defp relayed({:error, {:not_taken, _type}}), do: {:error, :not_taken}
  defp relayed({:error, reason}), do: {:error, reason}

  defp await_status(%{"attach_id" => attach_id}, context) do
    receive do
      {:upload_answer, "attach_status", %{"attach_id" => ^attach_id, "status" => status}} ->
        {:ok, status}

      {:upload_answer, "error", %{"code" => code}} ->
        {:error, {:refused, code}}

      {:upload_link_down, sentence} ->
        {:error, {:unreachable, sentence}}
    after
      context.answer_ms -> {:error, :timed_out}
    end
  end

  # -- words ------------------------------------------------------------------------------

  defp sentence({word, sentence}, _attachment, _read) when word in [:unreachable, :revoked],
    do: sentence

  defp sentence(:not_taken, _attachment, _read), do: @not_taken_sentence
  defp sentence(:busy, _attachment, _read), do: @busy_sentence

  defp sentence(reason, _attachment, _read) when reason in [:timed_out, :timeout],
    do: @timed_out_sentence

  defp sentence({:refused, code}, attachment, read),
    do: Inbox.describe_error(refused(code, attachment, read))

  defp sentence(reason, _attachment, _read), do: Inbox.describe_error(reason)

  # The server's refusal, in the reasons `Companion.Inbox` has words for.
  defp refused("media_too_large", attachment, {:ok, _bytes, max}),
    do: {:media_too_large, attachment["size_bytes"], max}

  defp refused("store_quota_exceeded", attachment, _read),
    do: {:store_quota_exceeded, attachment["size_bytes"]}

  defp refused("upload_limit_reached", _attachment, _read), do: :upload_limit_reached
  defp refused("store_upload_limit_reached", _attachment, _read), do: :store_upload_limit_reached
  defp refused("upload_exists", _attachment, _read), do: :upload_exists
  defp refused("attachment_exists", _attachment, _read), do: :attachment_exists

  defp refused("size_exceeded", attachment, _read),
    do: {:size_exceeded, attachment["size_bytes"], nil}

  defp refused("size_mismatch", attachment, _read),
    do: {:size_mismatch, attachment["size_bytes"], nil}

  defp refused("announced_hash_mismatch", attachment, _read),
    do: {:announced_hash_mismatch, attachment["sha256"], nil}

  defp refused("sha256_mismatch", _attachment, _read), do: {:sha256_mismatch, nil}

  defp refused(code, _attachment, _read) do
    Logger.warning("desktop uploads: the server refused an upload: #{code}")
    {:refused_by_server, code}
  end

  defp remove(dir, attach_id) do
    with true <- Protocol.attach_id?(attach_id),
         {:error, reason} when reason != :enoent <- File.rm(Path.join(dir, attach_id)) do
      Logger.error("desktop uploads could not remove #{attach_id}: #{inspect(reason)}")
    end

    :ok
  end
end
