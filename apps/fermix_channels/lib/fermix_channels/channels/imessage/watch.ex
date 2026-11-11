defmodule FermixChannels.Channels.IMessage.Watch do
  @moduledoc """
  On a Mac that carries Messages for its server (M97 §6.4), what the helper
  says, held for the server, and the door each of the server's requests goes
  through to this Mac's own helper (`IMessage.Capability`).

  **What the helper says.** It is the helper's one attached process
  (`IMessage.Helper.attach/2`): each notification (`message`,
  `watch.overflow`, `db.state`, `send.reconciled`, `policy.state`) and each
  time the helper comes up or goes down is kept as an event with its own
  sequence number, at most #{256}; past that the oldest go, and the next
  answer starts with a `watch.overflow` naming how many, so the server pages
  them from its cursor. Nothing here makes a turn.

  **The server's watch** (`next/3`, the long-lived `imessage.watch`) names
  the last event it took and the watch it took it from (this process's
  `boot`, new at each start). Events after it are answered at once, or as
  soon as one comes; what it took is let go. A watch it does not know (none,
  or one from before this process started) is answered at once with the
  helper's state now, and the server starts over from the cursor it keeps
  (`IMessage.Listener`). One watch waits at a time: a newer one ends the
  older with nothing, so a server that asked again after its link came back
  never leaves one behind.

  **A request** (`request/5`) runs in the caller's process, through the
  helper module this process was started with: `send.file` stages its bytes
  in the helper's outbox and fills `path` itself, removing the copy after;
  `attachment.fetch` reads the file the helper wrote into its inbox, answers
  its name, type and size with the bytes, and removes it. No path leaves
  this Mac.

  Options: `:name`, `:helper` (the `IMessage.Helper` module), `:server` (its
  process) and `:home` (this Mac's FERMIX_HOME, the root of the helper's
  inbox and outbox).
  """

  use GenServer

  require Logger

  alias FermixChannels.Channels.IMessage.Capability

  @max_events 256
  @max_part_bytes 20 * 1_024 * 1_024
  @not_running "Fermix Messages is not running on this Mac."

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  The events after `after_seq` of the watch `boot`, as soon as there is
  one: `{"boot", "seq", "events"}` (the moduledoc). Waits until then.
  """
  @spec next(GenServer.server(), integer() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, String.t()}
  def next(server, after_seq, boot) do
    GenServer.call(server, {:next, after_seq, boot}, :infinity)
  catch
    # Not running, or stopped while this watch waited: the server asks again.
    :exit, {reason, _call} when reason in [:noproc, :shutdown, :normal] ->
      {:error, @not_running}
  end

  @doc """
  Runs one helper request on this Mac (the moduledoc): `{:ok, result,
  part}`, the helper's own typed error, or `{:unavailable, sentence}` when
  no helper runs here or a file could not be staged or read.
  """
  @spec request(GenServer.server(), String.t(), map(), binary() | nil, map()) ::
          {:ok, map(), binary() | nil}
          | {:error, FermixChannels.Channels.IMessage.Helper.error()}
          | {:unavailable, String.t()}
  def request(server, method, params, part, args)
      when is_binary(method) and is_map(params) and is_map(args) do
    case helper(server) do
      {:ok, helper} -> perform(helper, method, params, part, args)
      :error -> {:unavailable, @not_running}
    end
  end

  defp helper(server) do
    {:ok, GenServer.call(server, :helper)}
  catch
    :exit, {:noproc, _call} -> :error
  end

  # -- GenServer ---------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      helper: Keyword.fetch!(opts, :helper),
      server: Keyword.fetch!(opts, :server),
      home: Keyword.fetch!(opts, :home),
      boot: Base.encode32(:crypto.strong_rand_bytes(10), case: :lower, padding: false),
      seq: 0,
      events: :queue.new(),
      count: 0,
      dropped: 0,
      dropped_seq: nil,
      lifecycle: %{"helper" => "down", "class" => "helper_not_started"},
      waiter: nil
    }

    {:ok, state, {:continue, :attach}}
  end

  @impl true
  def handle_continue(:attach, state) do
    case state.helper.attach(state.server, self()) do
      {:ok, handshake} -> {:noreply, lifecycle(state, up(handshake))}
      {:error, {_kind, _message, data}} -> {:noreply, lifecycle(state, down(data["class"]))}
    end
  end

  @impl true
  def handle_call(:helper, _from, state),
    do: {:reply, %{helper: state.helper, server: state.server, home: state.home}, state}

  def handle_call({:next, _after, boot}, _from, %{boot: mine} = state) when boot != mine do
    state = state |> supersede() |> drop_through(state.seq)
    snapshot = Map.put(state.lifecycle, "seq", state.seq)
    {:reply, {:ok, answer(state.boot, state.seq, [snapshot])}, %{state | dropped: 0}}
  end

  def handle_call({:next, after_seq, _boot}, from, state) do
    state = state |> drop_through(after_seq || 0) |> supersede()

    if state.count > 0 or state.dropped > 0 do
      {answer, state} = take(state)
      {:reply, {:ok, answer}, state}
    else
      {:noreply, park(state, from)}
    end
  end

  @impl true
  def handle_info({:imessage_event, event, params}, state),
    do: {:noreply, state |> add(%{"event" => event, "params" => params}) |> wake()}

  def handle_info({:imessage_helper, :up, handshake}, state),
    do: {:noreply, state |> lifecycle(up(handshake)) |> wake()}

  def handle_info({:imessage_helper, :down, class}, state),
    do: {:noreply, state |> lifecycle(down(class_word(class))) |> wake()}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{waiter: {_from, ref}} = state),
    do: {:noreply, %{state | waiter: nil}}

  def handle_info(message, state) do
    Logger.debug("the Messages watch ignored #{inspect(message)}")
    {:noreply, state}
  end

  # -- events ------------------------------------------------------------------------------

  defp up(handshake), do: %{"helper" => "up", "handshake" => handshake}
  defp down(class), do: %{"helper" => "down", "class" => class || "helper_unavailable"}

  defp lifecycle(state, event), do: add(%{state | lifecycle: event}, event)

  # Bounded: past the cap the oldest goes, and is counted for the next answer.
  defp add(state, event) do
    seq = state.seq + 1
    events = :queue.in(Map.put(event, "seq", seq), state.events)

    if state.count >= @max_events do
      {{:value, _oldest}, events} = :queue.out(events)
      %{state | seq: seq, events: events, dropped: state.dropped + 1}
    else
      %{state | seq: seq, events: events, count: state.count + 1}
    end
  end

  # What the server took is let go, the count of what overflowed with it once
  # the server took the answer that named it.
  defp drop_through(state, seq) do
    state = if state.dropped_seq && seq >= state.dropped_seq, do: forgive(state), else: state

    case :queue.peek(state.events) do
      {:value, %{"seq" => first}} when first <= seq ->
        {_taken, events} = :queue.out(state.events)
        drop_through(%{state | events: events, count: state.count - 1}, seq)

      _later_or_none ->
        state
    end
  end

  defp forgive(state), do: %{state | dropped: 0, dropped_seq: nil}

  # Everything held, after a `watch.overflow` naming what was let go.
  defp take(%{dropped: 0} = state),
    do: {answer(state.boot, state.seq, :queue.to_list(state.events)), state}

  defp take(state) do
    overflow = %{
      "seq" => state.seq,
      "event" => "watch.overflow",
      "params" => %{"dropped" => state.dropped}
    }

    events = [overflow | :queue.to_list(state.events)]
    {answer(state.boot, state.seq, events), %{state | dropped_seq: state.seq}}
  end

  defp answer(boot, seq, events), do: %{"boot" => boot, "seq" => seq, "events" => events}

  # -- the waiting watch -------------------------------------------------------------------

  defp park(state, {pid, _tag} = from),
    do: %{state | waiter: {from, Process.monitor(pid)}}

  # A newer watch ends the older one with nothing.
  defp supersede(%{waiter: nil} = state), do: state

  defp supersede(%{waiter: {from, ref}} = state) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(from, {:ok, answer(state.boot, state.seq, [])})
    %{state | waiter: nil}
  end

  defp wake(%{waiter: nil} = state), do: state

  defp wake(%{waiter: {from, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {answer, state} = take(state)
    GenServer.reply(from, {:ok, answer})
    %{state | waiter: nil}
  end

  defp class_word({:helper_exit, code}), do: "helper_exit #{code}"
  defp class_word({:helper_spawn_failed, _reason}), do: "helper_spawn_failed"
  defp class_word(class) when is_atom(class) and not is_nil(class), do: Atom.to_string(class)
  defp class_word(class) when is_binary(class), do: class
  defp class_word(_class), do: "helper_unavailable"

  # -- one request, in the caller's process --------------------------------------------------

  defp perform(helper, "send.file", params, part, args) when is_binary(part) do
    with {:ok, staged} <- stage(helper.home, Map.get(args, "file_name", "attachment"), part) do
      try do
        call(helper, "send.file", Map.put(params, "path", staged.path), args)
      after
        unstage(staged)
      end
    end
  end

  defp perform(_helper, "send.file", _params, nil, _args),
    do: {:unavailable, "The file did not come with the request."}

  defp perform(helper, "attachment.fetch", params, nil, args) do
    with {:ok, result, nil} <- call(helper, "attachment.fetch", params, args) do
      fetched(helper.home, params["message_guid"], result)
    end
  end

  defp perform(helper, method, params, nil, args), do: call(helper, method, params, args)

  defp perform(_helper, _method, _params, _part, _args),
    do: {:unavailable, "That request takes no file."}

  # This Mac's own helper: the turn's origin was decided at admission here.
  defp call(helper, method, params, %{"timeout_ms" => timeout}) do
    case helper.helper.call(helper.server, method, params, timeout, %{}) do
      {:ok, result} -> {:ok, result, nil}
      {:error, {_kind, _message, _data}} = error -> error
    end
  end

  # -- the outbox ------------------------------------------------------------------------------

  defp stage(home, name, bytes) do
    outbox = Path.join([home, "imessage", "outbox"])
    dir = Path.join(outbox, Base.encode32(:crypto.strong_rand_bytes(10), case: :lower))
    path = Path.join(dir, name)

    with :ok <- private_dir(Path.join(home, "imessage")),
         :ok <- private_dir(outbox),
         :ok <- private_dir(dir),
         :ok <- File.write(path, bytes),
         :ok <- File.chmod(path, 0o600) do
      {:ok, %{dir: dir, path: path}}
    else
      {:error, reason} ->
        Logger.error("Messages could not stage a file in its outbox: #{inspect(reason)}")
        {:unavailable, "This Mac could not stage the file for Messages."}
    end
  end

  # Removes exactly what `stage/3` made.
  defp unstage(%{dir: dir, path: path}) do
    for {result, what} <- [{File.rm(path), "file"}, {File.rmdir(dir), "folder"}],
        not match?(:ok, result),
        do: Logger.error("Messages left a staged #{what} in its outbox: #{inspect(result)}")

    :ok
  end

  defp private_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
  end

  # -- the inbox -------------------------------------------------------------------------------

  # The file the helper wrote for this message, read and then removed: the
  # server keeps its own copy. One outside the message's own inbox entry is
  # refused, so nothing else is ever read or removed.
  defp fetched(home, guid, %{"path" => path} = result) when is_binary(guid) and is_binary(path) do
    entry = Path.join([Path.expand(home), "imessage", "inbox", guid])
    expanded = Path.expand(path)

    with true <- Path.dirname(expanded) == entry,
         {:ok, %{type: :regular, size: size}} when size <= @max_part_bytes <- File.lstat(expanded),
         {:ok, bytes} <- File.read(expanded) do
      :ok = remove_fetched(expanded, entry)

      {:ok, %{"name" => Path.basename(expanded), "mime" => result["mime"], "bytes" => size},
       bytes}
    else
      false -> {:error, {:path_refused, "the helper's file is outside the message's inbox", %{}}}
      {:ok, %{type: :regular, size: size}} -> too_large(size)
      other -> unreadable(other)
    end
  end

  defp fetched(_home, _guid, result),
    do:
      {:error,
       {:protocol_error, "attachment.fetch answered no path", %{"keys" => Map.keys(result)}}}

  defp remove_fetched(path, entry) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Messages could not remove a fetched file: #{inspect(reason)}")
    end

    # The entry holds the message's other attachments until they are fetched.
    case File.rmdir(entry) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eexist, :enotempty, :enoent] ->
        :ok

      {:error, reason} ->
        Logger.error("Messages could not remove an inbox entry: #{inspect(reason)}")
    end
  end

  defp too_large(size),
    do:
      {:error,
       {:attachment_too_large,
        "the attachment is #{size} bytes; Messages through a computer carries at most " <>
          "#{div(Capability.max_part_bytes(), 1_048_576)} MiB", %{"bytes" => size}}}

  defp unreadable(reason) do
    Logger.error("Messages could not read a fetched attachment: #{inspect(reason)}")
    {:unavailable, "This Mac could not read the attachment Messages fetched."}
  end
end
