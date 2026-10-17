defmodule FermixChannels.Channels.Mobile do
  @moduledoc """
  Channel adapter for the authenticated iOS companion transport.

  The adapter owns no socket or cipher state. It converts decoded client events
  into gateway messages and broadcasts server events by profile. The listener
  is the only caller allowed to construct the explicit authenticated ingress
  context consumed by `ingest_event/3`.

  A turn streams and writes its own rows as it runs; `Companion.Turns` settles
  its request from the queue's outcome, and this adapter adds only the phone's
  own effect of a completed turn, its push.

  A phone turn runs in the Mac's chat (`joined_conversation/1`, M56 D9): one
  agent history and one queue lane for the one timeline both draw. The
  channel stays `mobile`, so the phone's authorization, approval cards,
  stream and push stay its own. A row it writes is previewed as every row of
  the timeline is (`FermixChannels.LinkPreviews`).
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Channels.Companion
  alias FermixChannels.Companion.Approvals
  alias FermixChannels.Companion.Fanout
  alias FermixChannels.Companion.Output
  alias FermixChannels.Companion.Turns
  alias FermixChannels.Gateway.Channel
  alias FermixChannels.Gateway.Commands.Registry, as: CommandRegistry
  alias FermixChannels.Gateway.Message
  alias FermixChannels.LinkPreviews
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.Push
  alias FermixChannels.Mobile.Supervisor, as: MobileSupervisor
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Companion.Timeline
  alias FermixCore.Reply
  alias FermixCore.ReplyBlocks
  alias FermixCore.Telemetry

  @channel "mobile"
  @profile "main"
  @media_chunk_bytes 60 * 1_024
  @max_media_bytes 20 * 1_024 * 1_024

  @type event :: %{required(:type) => String.t(), required(:payload) => map()}
  @type draft_handle :: %{turn_id: String.t(), state: pid()}

  @spec channel() :: String.t()
  def channel, do: @channel

  @spec parse_event(event()) :: {:ok, [Message.t()]} | {:error, term()}
  def parse_event(event) do
    {result, duration_us} = Telemetry.timed_us(fn -> do_parse_event(event) end)
    ChannelTelemetry.emit_parse(:mobile, result, duration_us)
    result
  end

  defp do_parse_event(%{type: "msg", payload: payload}) when is_map(payload) do
    with {:ok, profile} <- profile(payload),
         {:ok, client_id} <- required(payload, "client_msg_id"),
         {:ok, text} <- binary(payload, "text"),
         {:ok, attachments} <- attachments(payload) do
      {:ok, [message(client_id, profile, text, attachments, "msg")]}
    end
  end

  defp do_parse_event(%{type: "command", payload: payload}) when is_map(payload) do
    with {:ok, profile} <- profile(payload),
         {:ok, client_id} <- required(payload, "client_msg_id"),
         {:ok, command} <- command_text(payload) do
      {:ok, [message(client_id, profile, command, [], "command")]}
    end
  end

  defp do_parse_event(%{type: type}) when is_binary(type),
    do: {:error, {:unsupported_event, type}}

  defp do_parse_event(_event), do: {:error, :invalid_event}

  @doc "Route a decoded, authenticated client event into the mobile session coordinator."
  @spec ingest_event(map(), map(), keyword()) :: :ok | {:error, term()}
  def ingest_event(event, ingress_context, opts \\ [])
      when is_map(event) and is_map(ingress_context) and is_list(opts) do
    EventRouter.route(event, ingress_context, opts)
  end

  @doc "Command-palette entries derived from the live command registry."
  @spec command_catalog() :: [map()]
  def command_catalog do
    Enum.map(CommandRegistry.list(), fn command ->
      %{
        "name" => command.name(),
        "aliases" => command.aliases(),
        "description" => command.description()
      }
    end)
  end

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  def stream_capability, do: :draft_edit

  # The phone's socket has no platform edit budget, so a draft streams at a
  # tenth of a second, from its first character, with no edit cap (D8).
  @impl true
  def draft_pacing, do: %{edit_interval_ms: 100, min_draft_chars: 1, max_edits: :infinity}

  # A draft edit only shows the phones the reply; the seal is the one write
  # that stores it and completes its request, so it is never skipped.
  @impl true
  def seal_persists?, do: true

  @impl true
  def terminal_error_capability, do: :turn_result

  @impl true
  def build_text_reply(%Message{reply_target: profile_id} = message) do
    opts = reply_opts(message)
    fn text -> send_message(profile_id, text, opts) end
  end

  @impl true
  def build_media_reply(%Message{reply_target: profile_id} = message) do
    opts = reply_opts(message)
    fn media -> send_media(profile_id, media, opts) end
  end

  @impl true
  def open_draft(%Message{} = message, text) when is_binary(text) do
    with {:ok, state} <- Agent.start_link(fn -> text end) do
      handle = %{turn_id: turn_id(message), state: state}

      case emit_open(message, handle.turn_id, text) do
        :ok ->
          {:ok, handle}

        {:error, reason} ->
          Agent.stop(state, :normal)
          {:error, reason}
      end
    end
  end

  @impl true
  def edit_draft(%Message{} = message, %{turn_id: turn_id, state: state}, text)
      when is_binary(turn_id) and is_pid(state) and is_binary(text) do
    delta = Agent.get_and_update(state, fn prior -> {draft_delta(prior, text), text} end)
    emit_delta(message.chat_id, turn_id, delta)
  end

  @impl true
  def seal_draft(%Message{} = message, %{turn_id: turn_id, state: state}, text)
      when is_binary(turn_id) and is_pid(state) and is_binary(text) do
    with {:ok, {status, row}} <- persist_final_text(message, text) do
      _ = emit_after_commit(message.chat_id, Output.text_done(turn_id, row.server_seq, text))
      _ = announce_to_companion(status, message.chat_id, row)

      _ =
        LinkPreviews.schedule(message.chat_id, row.server_seq, ReplyBlocks.links(text),
          store: store()
        )

      {:ok, nil}
    end
  after
    stop_draft_state(state)
  end

  @impl true
  def discard_draft(%Message{}, %{turn_id: turn_id, state: state})
      when is_binary(turn_id) and is_pid(state) do
    stop_draft_state(state)
  end

  # A provider call is not a tool: `tool_event` is a tool's lifecycle, named,
  # never the model call that picks it. The turn's thinking state already
  # reaches the phone through `turn_started` and the first `text_delta`.
  @impl true
  def build_activity_callback(%Message{} = message) do
    turn_id = turn_id(message)

    fn
      :provider_start -> :ok
      :provider_response -> :ok
      event -> emit(message.chat_id, Output.tool_event(turn_id, event))
    end
  end

  @impl true
  def build_turn_result(%Message{} = message) do
    fn outcome ->
      with {:ok, settled} <- Turns.outcome(message, outcome) do
        schedule_request_push(message.chat_id, settled)
      end
    end
  end

  @impl true
  def reaction_capability, do: :any_emoji

  @impl true
  def react(%Message{} = message, emoji) when is_binary(emoji) do
    emit(message.chat_id, %{
      "t" => "reaction",
      "in_reply_to" => client_message_id(message),
      "emoji" => emoji
    })
  end

  @impl true
  def send_approval(%Message{} = message, text, token)
      when is_binary(text) and is_binary(token) do
    send_approval(message, %{kind: :sandbox, text: text, token: token})
  end

  @doc """
  Deliver a kind-aware mobile approval with exact approve and deny routes, to
  the phones alone: its token resolves only from the phone (M19 §9.5). The
  card is kept until it resolves or expires, for a phone that connects later,
  and a phone that is away is told, with no content, that an approval waits.
  """
  @impl true
  @spec send_approval(Message.t(), map()) :: :ok | {:error, term()}
  def send_approval(%Message{} = message, %{kind: kind, text: text, token: token} = spec)
      when kind in [:sandbox, :soul] and is_binary(text) and is_binary(token) do
    :ok = Approvals.announce(Approvals.server(), message.chat_id, Output.approval(spec), :mobile)
    launch_push(fn -> notify_approval(message.chat_id) end, [])
  end

  @impl true
  def start_typing(profile_id) when is_binary(profile_id), do: :ok

  @doc """
  The owner's inbox on this channel (M56 §4.7): the shared chat's profile,
  only while the phone channel runs. A send here is a row and its push, and
  with the channel off it would be a row the Mac alone hears, which is the
  companion channel's send, not this one's.
  """
  @impl true
  @spec owner_inbox() :: {:ok, String.t()} | :unavailable
  def owner_inbox do
    if MobileSupervisor.running?(), do: {:ok, @profile}, else: :unavailable
  end

  @doc """
  The conversation a phone message runs in (M56 D9): the Mac's chat of the
  same profile, so the phone's turns and the Mac's share one agent history and
  wait for each other in one queue lane, as they share one timeline. The
  gateway puts it on every message it ingests through this adapter, a resumed
  request's included.
  """
  @impl true
  @spec joined_conversation(Message.t()) :: {String.t(), String.t(), :root}
  def joined_conversation(%Message{chat_id: profile}), do: Companion.conversation_key(profile)

  @impl true
  def health_check(opts) when is_list(opts) do
    management = Keyword.get(opts, :management, Management)

    case management.health() do
      {:ok, %{listener: :ready, identity: :ready, paired_devices: count}}
      when is_integer(count) and count >= 0 ->
        {:ok, %{detail: "mobile listener ready; identity ready; #{count} paired device(s)"}}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:invalid_mobile_health, other}}
    end
  end

  @doc """
  The id of the turn that answers the phone's request `client_msg_id`: the
  one its stream and its ending name, whether or not a turn ran for it.
  """
  @spec request_turn_id(String.t()) :: String.t()
  def request_turn_id(client_msg_id) when is_binary(client_msg_id) and client_msg_id != "",
    do: "turn-" <> client_msg_id

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), Channel.send_opts()) :: :ok | {:error, term()}
  def send_message(profile_id, text, opts \\ [])
      when is_binary(profile_id) and is_binary(text) and is_list(opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        with :ok <- validate_profile(profile_id),
             {:ok, {status, row}} <- Output.persist_text(store(), profile_id, text, Map.new(opts)),
             :ok <- deliver_persisted_text(status, profile_id, text, row, opts) do
          {:ok, status}
        end
      end)

    emit_outbound(result, duration_us)
  end

  @impl true
  @spec send_media(String.t(), Reply.media_part()) :: :ok | {:error, term()}
  @spec send_media(String.t(), Reply.media_part(), Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_media(profile_id, media, opts \\ [])
      when is_binary(profile_id) and is_map(media) and is_list(opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        with :ok <- validate_profile(profile_id),
             :ok <- validate_proactive_media_opts(opts),
             {:ok, ref} <- resolve_outbound_media(media),
             {:ok, {status, row}} <- persist_media(profile_id, media, ref, Map.new(opts)),
             :ok <- deliver_persisted_media(status, profile_id, media, ref, row, opts) do
          {:ok, status}
        end
      end)

    emit_outbound(result, duration_us)
  end

  @impl true
  def download_attachment(_message, attachment) when is_map(attachment) do
    case value(attachment, :path) do
      path when is_binary(path) ->
        if File.regular?(path), do: {:ok, path}, else: {:error, :attachment_unavailable}

      _other ->
        materialize_attachment(value(attachment, :file_id))
    end
  end

  @doc "Queue one APNs decision for the exact durable timeline row."
  @spec schedule_push(String.t(), pos_integer(), keyword()) :: :ok
  def schedule_push(profile_id, server_seq, opts \\ [])
      when is_binary(profile_id) and is_integer(server_seq) and server_seq > 0 and
             is_list(opts) do
    task = fn -> notify_timeline_row(profile_id, server_seq, opts) end
    launch_push(task, opts)
  end

  defp message(client_id, profile, text, attachments, request_type) do
    Message.new!(%{
      id: client_id,
      content: text,
      sender: "Mobile owner",
      channel: @channel,
      chat_id: profile,
      reply_target: profile,
      metadata: %{
        client_msg_id: client_id,
        mobile_request_type: request_type,
        turn_id: request_turn_id(client_id)
      },
      attachments: attachments
    })
  end

  defp attachments(payload), do: {:ok, Map.get(payload, "attachments", [])}

  defp profile(payload) do
    with {:ok, profile} <- required(payload, "profile_id"),
         :ok <- validate_profile(profile) do
      {:ok, profile}
    end
  end

  defp validate_profile(@profile), do: :ok
  defp validate_profile(_profile), do: {:error, :unsupported_profile}

  defp command_text(payload) do
    with {:ok, name} <- required(payload, "name"),
         true <- Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) do
      args = Map.get(payload, "args", "")

      if is_binary(args),
        do: {:ok, String.trim("/#{name} #{args}")},
        else: {:error, :invalid_command}
    else
      _other -> {:error, :invalid_command}
    end
  end

  defp required(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_field, key}}
    end
  end

  defp binary(payload, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp reply_opts(message),
    do: [
      turn_id: turn_id(message),
      in_reply_to: client_message_id(message),
      request_type: value(message.metadata, :mobile_request_type),
      attempt: value(message.metadata, :mobile_attempt)
    ]

  defp turn_id(%Message{metadata: metadata}), do: value(metadata, :turn_id) || new_turn_id()

  defp client_message_id(%Message{} = message),
    do: value(message.metadata, :client_msg_id) || message.id

  defp persist_final_text(message, text) do
    attrs = %{
      turn_id: turn_id(message),
      in_reply_to: client_message_id(message),
      attempt: request_attempt(message)
    }

    Output.persist_final_text(store(), message.chat_id, attrs, text)
  end

  defp persist_media(profile_id, media, ref, attrs) do
    timeline_ref = timeline_media_ref(media, ref)

    timeline_attrs = %{
      role: "assistant",
      content: value(media, :caption) || "",
      kind: "media",
      in_reply_to: value(attrs, :in_reply_to),
      media_refs: [timeline_ref]
    }

    Output.persist_output(
      store(),
      profile_id,
      timeline_attrs,
      attrs,
      media_output_key(timeline_ref)
    )
  end

  defp media_output_key(ref), do: "media:" <> value(ref, :ref)

  defp deliver_persisted_text(:existing, _profile, _text, _row, _opts), do: :ok

  defp deliver_persisted_text(:created, profile, text, row, opts) do
    _ = emit_after_commit(profile, delivered_text(profile, text, row, opts))
    _ = announce_to_companion(:created, profile, row)
    delivered_effects(profile, row.server_seq, text, opts)
  end

  # A request's reply seals a bubble of its turn, which the request's own
  # ending closes. Anything else (a job, a reminder, a background result) is
  # a delivery no turn streamed, and reaches the phones as the row it is, so
  # it opens no turn that nothing would end (mobile protocol 2).
  defp delivered_text(profile, text, row, opts) do
    case Keyword.get(opts, :turn_id) do
      nil -> Output.row(profile, row)
      turn_id -> Output.text_done(turn_id, row.server_seq, text)
    end
  end

  defp deliver_persisted_media(:existing, _profile, _media, _ref, _row, _opts), do: :ok

  defp deliver_persisted_media(:created, profile, media, ref, row, opts) do
    _ = emit_media_after_commit(profile, row.server_seq, media, ref)
    _ = announce_to_companion(:created, profile, row)
    delivered_effects(profile, row.server_seq, value(media, :caption) || "", opts)
  end

  # A delivered row's push is for phones, so it is launched only while the
  # phone subtree runs (`Mobile.Supervisor.running?/1`): a job or reminder
  # delivered here while it does not is still a row of the shared timeline,
  # which the Mac has heard, and nobody is pushed. Its links are previewed
  # either way, as every row's are.
  defp delivered_effects(profile, server_seq, text, opts) do
    _ =
      if MobileSupervisor.running?(), do: maybe_schedule_proactive_push(profile, server_seq, opts)

    LinkPreviews.schedule(profile, server_seq, ReplyBlocks.links(text), store: store())
  end

  # One durable timeline row is one delivered outbound message. A row the store
  # deduplicated (`:existing`) was already counted when it was created, so a
  # proactive retry never inflates the channel's message count.
  defp emit_outbound({:ok, :created}, duration_us) do
    ChannelTelemetry.emit_message(:mobile, :outbound, 1, duration_us)
  end

  defp emit_outbound({:ok, :existing}, _duration_us), do: :ok
  defp emit_outbound({:error, reason}, _duration_us), do: {:error, reason}

  defp validate_proactive_media_opts(opts) do
    case {Keyword.get(opts, :proactive_key), Keyword.get(opts, :proactive_part_id)} do
      {nil, _part_id} ->
        :ok

      {key, part_id} when is_binary(key) and key != "" and is_binary(part_id) and part_id != "" ->
        :ok

      {_key, _part_id} ->
        {:error, :proactive_media_key_requires_part_id}
    end
  end

  # Every row this channel writes reaches the Mac's companion connections as it
  # is written; a row the store deduplicated was announced when it was created.
  defp announce_to_companion(:created, profile_id, row),
    do: Fanout.announce(profile_id, Output.row(profile_id, row), audience: :companion)

  defp announce_to_companion(:existing, _profile_id, _row), do: :ok

  defp emit_after_commit(profile_id, event) do
    case emit(profile_id, event) do
      :ok -> :ok
      {:error, reason} -> log_post_commit_error(:socket_fanout, reason)
    end
  end

  defp emit_media_after_commit(profile_id, server_seq, media, ref) do
    case emit_media(profile_id, server_seq, media, ref) do
      :ok -> :ok
      {:error, reason} -> log_post_commit_error(:media_fanout, reason)
    end
  end

  defp maybe_schedule_proactive_push(profile_id, server_seq, opts) do
    if Keyword.has_key?(opts, :in_reply_to) and not is_nil(Keyword.get(opts, :in_reply_to)),
      do: :ok,
      else: schedule_push(profile_id, server_seq)
  end

  defp launch_push(task, opts) do
    launcher =
      Keyword.get(opts, :push_launcher) ||
        Application.get_env(:fermix_channels, :mobile_push_launcher) ||
        (&default_push_launcher/1)

    case launcher.(task) do
      :ok -> :ok
      {:ok, _pid} -> :ok
      {:error, reason} -> log_post_commit_error(:push_launch, reason)
      other -> log_post_commit_error(:invalid_push_launcher_result, other)
    end
  end

  defp default_push_launcher(task),
    do: Task.Supervisor.start_child(FermixCore.TaskSupervisor, task)

  defp notify_timeline_row(profile_id, server_seq, opts) do
    with {:ok, preview} <- timeline_preview(profile_id, server_seq, opts),
         {:ok, _status} <- push_notify(profile_id, server_seq, preview, opts) do
      :ok
    else
      {:error, reason} -> log_post_commit_error(:push, reason)
    end
  end

  defp timeline_preview(profile_id, server_seq, opts) do
    history_opts = [after_seq: server_seq - 1, limit: 1] ++ Keyword.get(opts, :store_opts, [])
    store_module = Keyword.get(opts, :store, store())

    case store_module.history_page(profile_id, history_opts) do
      {:ok, %{messages: [%{server_seq: ^server_seq} = row | _rest]}} -> {:ok, row_preview(row)}
      {:ok, _page} -> {:error, {:timeline_row_not_found, server_seq}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_preview(row) do
    case value(row, :content) do
      text when is_binary(text) and text != "" -> text
      _empty -> "Sent an #{row_media_kind(row)}"
    end
  end

  defp row_media_kind(row) do
    case value(row, :media_refs) do
      [ref | _rest] -> value(ref, :kind) || "attachment"
      _other -> "message"
    end
  end

  # Push decides itself whether a phone is connected and whether it is
  # configured at all.
  defp notify_approval(profile_id) do
    override = Application.get_env(:fermix_channels, :mobile_approval_push)

    result =
      case injected(override, 1, :mobile_approval_push) do
        nil -> Push.notify_approval(profile_id)
        notify -> notify.(profile_id)
      end

    case result do
      {:ok, _status} -> :ok
      {:error, reason} -> log_post_commit_error(:approval_push, reason)
    end
  end

  defp push_notify(profile_id, server_seq, preview, opts) do
    override = Keyword.get(opts, :push) || Application.get_env(:fermix_channels, :mobile_push)

    case injected(override, 3, :mobile_push) do
      nil -> Push.notify(profile_id, server_seq, preview)
      notify -> notify.(profile_id, server_seq, preview)
    end
  end

  # An override either has the shape its call site uses, or the injection is
  # wrong and says so here. Quietly selecting the real implementation for a
  # mis-shaped override is how a unit test reached the live network.
  defp injected(nil, _arity, _name), do: nil
  defp injected(fun, arity, _name) when is_function(fun, arity), do: fun

  defp injected(other, arity, name) do
    raise ArgumentError,
          "mobile #{name} override must be a function of arity #{arity}, got: #{inspect(other)}"
  end

  defp log_post_commit_error(effect, reason) do
    Logger.error("mobile post-commit #{effect} failed: #{inspect(reason)}")
    :ok
  end

  defp resolve_outbound_media(media) do
    override = Application.get_env(:fermix_channels, :mobile_media_resolver)

    case injected(override, 1, :mobile_media_resolver) do
      nil -> store_outbound_media(media)
      resolver -> resolver.(media)
    end
  end

  defp store_outbound_media(media) do
    case value(media, :path) do
      path when is_binary(path) and path != "" -> store_outbound_path(path, media)
      _other -> {:error, :media_unavailable}
    end
  end

  defp store_outbound_path(path, media) do
    with {:ok, %{type: :regular, size: size}} <- File.stat(path),
         :ok <- validate_media_size(size),
         {:ok, bytes} <- File.read(path),
         {:ok, ref} <- MediaStore.put_bytes(MediaStore, bytes, media_metadata(media)),
         {:ok, blob} <- MediaStore.fetch(MediaStore, ref) do
      {:ok,
       %{
         "ref" => ref,
         "sha256" => ref,
         "path" => blob.path,
         "size_bytes" => blob.size_bytes,
         "kind" => media |> value(:kind) |> to_string(),
         "mime" => value(media, :mime_type) || "application/octet-stream"
       }}
    else
      {:ok, _not_regular} -> {:error, :media_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_media_size(size) when size <= @max_media_bytes, do: :ok
  defp validate_media_size(size), do: {:error, {:byte_cap_exceeded, size, @max_media_bytes}}

  defp media_metadata(media) do
    %{
      kind: value(media, :kind),
      mime_type: value(media, :mime_type),
      file_name: value(media, :filename)
    }
  end

  defp timeline_media_ref(media, ref) do
    %{
      "ref" => value(ref, :ref),
      "sha256" => value(ref, :sha256) || value(ref, :ref),
      "kind" => media |> value(:kind) |> to_string(),
      "mime" => value(media, :mime_type) || "application/octet-stream",
      "size_bytes" => value(ref, :size_bytes)
    }
    |> maybe_put("filename", value(media, :filename))
    |> maybe_put("caption", value(media, :caption))
  end

  @doc "The timeline this channel writes through (a test injects another)."
  @spec store() :: module()
  def store, do: Application.get_env(:fermix_channels, :mobile_store, Timeline)

  @doc """
  Send one logical event to every device connected under `profile_id` through
  `registry`, without waiting: while the mobile subtree does not run, nobody is
  connected and nothing is sent.
  """
  @spec broadcast(String.t(), map(), GenServer.server()) :: :ok
  def broadcast(profile_id, event, registry \\ DeviceRegistry)
      when is_binary(profile_id) and is_map(event) do
    case Application.get_env(:fermix_channels, :mobile_event_sink) do
      nil ->
        DeviceRegistry.broadcast(registry, profile_id, event)

      sink when is_function(sink, 2) ->
        sink.(profile_id, event)

      other ->
        raise ArgumentError,
              ":mobile_event_sink must be a 2-arity function, got: #{inspect(other)}"
    end
  end

  defp emit(profile_id, event), do: broadcast(profile_id, event)

  defp emit_open(message, turn_id, text) do
    started = Output.turn_started(message.chat_id, turn_id, client_message_id(message))

    with :ok <- emit(message.chat_id, started) do
      emit_delta(message.chat_id, turn_id, {:append, text})
    end
  end

  defp emit_delta(_profile, _turn_id, {:append, ""}), do: :ok

  defp emit_delta(profile, turn_id, {:append, text}),
    do: emit(profile, Output.text_delta(turn_id, text))

  defp emit_delta(profile, turn_id, {:replace, text}),
    do: emit(profile, turn_id |> Output.text_delta(text) |> Map.put("replace", true))

  defp media_begin(seq, media, ref) do
    %{
      "t" => "media_begin",
      "server_seq" => seq,
      "kind" => media |> value(:kind) |> to_string(),
      "mime" => value(media, :mime_type) || "application/octet-stream",
      "ref" => value(ref, :ref),
      "size_bytes" => value(ref, :size_bytes),
      "sha256" => value(ref, :sha256) || value(ref, :ref)
    }
    |> maybe_put("filename", value(media, :filename))
    |> maybe_put("caption", value(media, :caption))
  end

  defp emit_media(profile, seq, media, ref) do
    with :ok <- emit(profile, media_begin(seq, media, ref)),
         :ok <- emit_media_chunks(profile, ref),
         :ok <-
           emit(profile, %{
             "t" => "media_end",
             "ref" => value(ref, :ref),
             "sha256" => value(ref, :sha256) || value(ref, :ref)
           }) do
      :ok
    end
  end

  defp emit_media_chunks(profile, ref) do
    path = value(ref, :path)

    with true <- is_binary(path) and File.regular?(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        io
        |> IO.binstream(@media_chunk_bytes)
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {bytes, index}, :ok ->
          event = %{
            "t" => "media_chunk",
            "ref" => value(ref, :ref),
            "index" => index,
            "bytes" => bytes
          }

          if emit(profile, event) == :ok,
            do: {:cont, :ok},
            else: {:halt, {:error, :fanout_failed}}
        end)
      after
        File.close(io)
      end
    else
      false -> {:error, :media_unavailable}
      {:error, reason} -> {:error, {:media_open_failed, reason}}
    end
  end

  # What a draft edit sends: the text it grew by, or, when the draft was
  # rewritten rather than grown, its whole text, to replace what the phone
  # shows (mobile protocol 2).
  defp draft_delta(prior, text) do
    if String.starts_with?(text, prior),
      do: {:append, binary_part(text, byte_size(prior), byte_size(text) - byte_size(prior))},
      else: {:replace, text}
  end

  defp materialize_attachment(attach_id) when is_binary(attach_id) do
    case MediaStore.materialize_attachment(MediaStore, attach_id) do
      {:ok, %{path: path}} -> validate_materialized_path(path)
      {:ok, descriptor} -> {:error, {:invalid_attachment_descriptor, descriptor}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_attachment(_attach_id), do: {:error, :attachment_unavailable}

  defp validate_materialized_path(path) when is_binary(path) do
    if File.regular?(path), do: {:ok, path}, else: {:error, :attachment_unavailable}
  end

  defp validate_materialized_path(_path), do: {:error, :attachment_unavailable}

  # A turn that did not complete, or had no request behind it, pushes nothing.
  defp schedule_request_push(_profile_id, nil), do: :ok

  defp schedule_request_push(profile_id, request) do
    case value(request, :result_server_seq) do
      server_seq when is_integer(server_seq) and server_seq > 0 ->
        schedule_push(profile_id, server_seq)

      _none ->
        :ok
    end
  end

  defp request_attempt(message), do: value(message.metadata, :mobile_attempt)

  defp stop_draft_state(state) do
    if Process.alive?(state), do: Agent.stop(state, :normal)
    :ok
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp new_turn_id, do: "turn-#{System.unique_integer([:positive, :monotonic])}"
end
