defmodule FermixChannels.Channels.Mobile do
  @moduledoc """
  Channel adapter for the authenticated iOS companion transport.

  The adapter owns no socket or cipher state. It converts decoded client events
  into gateway messages and broadcasts server events by profile. The listener
  is the only caller allowed to construct the explicit authenticated ingress
  context consumed by `ingest_event/3`.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Gateway.Channel
  alias FermixChannels.Gateway.Commands.Registry, as: CommandRegistry
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Mobile.DeviceRegistry
  alias FermixChannels.Mobile.EventRouter
  alias FermixChannels.Mobile.Management
  alias FermixChannels.Mobile.MediaStore
  alias FermixChannels.Mobile.Push
  alias FermixChannels.Mobile.Unfurl
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Mobile.Store
  alias FermixCore.Reply
  alias FermixCore.Telemetry

  @channel "mobile"
  @profile "main"
  @sandbox_ttl_s 60
  @soul_ttl_s 300
  @media_chunk_bytes 60 * 1_024
  @max_media_bytes 20 * 1_024 * 1_024

  @type event :: %{required(:type) => String.t(), required(:payload) => map()}
  @type draft_handle :: %{turn_id: String.t(), state: pid()}

  @spec channel() :: String.t()
  def channel, do: @channel

  @doc "Stable opaque identifier shared by approval and resolution events."
  @spec approval_id(:sandbox | :soul, String.t()) :: String.t()
  def approval_id(kind, token)
      when kind in [:sandbox, :soul] and is_binary(token) and token != "" do
    digest = :crypto.hash(:sha256, "#{kind}:#{token}")
    "#{kind}-" <> Base.url_encode64(digest, padding: false)
  end

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
    delta = Agent.get_and_update(state, fn prior -> {suffix(prior, text), text} end)
    emit_delta(message.chat_id, turn_id, delta)
  end

  @impl true
  def seal_draft(%Message{} = message, %{turn_id: turn_id, state: state}, text)
      when is_binary(turn_id) and is_pid(state) and is_binary(text) do
    with {:ok, {_status, row}} <- persist_final_text(message, text) do
      _ = emit_after_commit(message.chat_id, text_done(turn_id, row.server_seq, text))
      _ = schedule_unfurl(message.chat_id, row.server_seq, text)
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

  @impl true
  def build_activity_callback(%Message{} = message) do
    turn_id = turn_id(message)
    fn event -> emit(message.chat_id, tool_event(turn_id, event)) end
  end

  @impl true
  def build_turn_result(%Message{} = message) do
    turn_id = turn_id(message)

    fn
      {:completed} -> settle_turn_and_notify(message, :completed)
      {:cancelled} -> fail_emit_and_notify(message, turn_id, :cancelled)
      {:failed, reason} -> fail_emit_and_notify(message, turn_id, reason)
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

  @doc "Deliver a kind-aware mobile approval with exact approve and deny routes."
  @impl true
  @spec send_approval(Message.t(), map()) :: :ok | {:error, term()}
  def send_approval(%Message{} = message, %{kind: kind, text: text, token: token} = spec)
      when kind in [:sandbox, :soul] and is_binary(text) and is_binary(token) do
    {approve, deny, ttl} = approval_routes(kind, token)
    clean_text = text |> scrub_command(approve) |> scrub_command(deny) |> String.trim()

    emit(message.chat_id, %{
      "t" => "approval",
      "approval_id" => Map.get(spec, :approval_id, approval_id(kind, token)),
      "kind" => Atom.to_string(kind),
      "text" => clean_text,
      "detail" => Map.get(spec, :detail),
      "token" => token,
      "ttl_s" => Map.get(spec, :ttl_s, ttl),
      "approve_command" => approve,
      "deny_command" => deny
    })
  end

  @impl true
  def start_typing(profile_id) when is_binary(profile_id), do: :ok

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

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), Channel.send_opts()) :: :ok | {:error, term()}
  def send_message(profile_id, text, opts \\ [])
      when is_binary(profile_id) and is_binary(text) and is_list(opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        with :ok <- validate_profile(profile_id),
             {:ok, {status, row}} <- persist_text(profile_id, text, Map.new(opts)),
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

  @doc """
  Resolve and fan out link previews asynchronously after a durable timeline commit.

  An injected `:unfurl` resolver is called as `resolver.(text, store_thumbnail)`,
  the same shape `Unfurl.resolve/2` receives, so every resolver reaches the
  writer that attaches a thumbnail to the durable row before it is announced.
  """
  @spec schedule_unfurl(String.t(), pos_integer(), String.t(), keyword()) :: :ok
  def schedule_unfurl(profile_id, server_seq, text, opts \\ [])
      when is_binary(profile_id) and is_integer(server_seq) and server_seq > 0 and
             is_binary(text) and is_list(opts) do
    if text == "" do
      :ok
    else
      launch_unfurl(fn -> resolve_unfurls(profile_id, server_seq, text, opts) end, opts)
    end
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
        turn_id: "turn-" <> client_id
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

  defp persist_text(profile_id, text, attrs) do
    timeline_attrs = text_timeline_attrs(text, attrs)

    persist_output(profile_id, timeline_attrs, attrs, text_output_key(text))
  end

  defp persist_final_text(message, text) do
    attrs = %{
      turn_id: turn_id(message),
      in_reply_to: client_message_id(message),
      attempt: request_attempt(message)
    }

    store().append_client_response(
      message.chat_id,
      client_message_id(message),
      request_attempt(message),
      attrs |> text_timeline_attrs(text) |> Map.delete(:role),
      []
    )
  end

  defp text_timeline_attrs(attrs, text) when is_map(attrs) and is_binary(text),
    do: text_timeline_attrs(text, attrs)

  defp text_timeline_attrs(text, attrs) do
    %{
      role: "assistant",
      content: text,
      kind: "text",
      in_reply_to: value(attrs, :in_reply_to),
      metadata: %{"turn_id" => value(attrs, :turn_id)}
    }
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

    persist_output(profile_id, timeline_attrs, attrs, media_output_key(timeline_ref))
  end

  defp persist_output(profile_id, timeline_attrs, attrs, output_key) do
    cond do
      client_output?(attrs) ->
        store().append_client_output(
          profile_id,
          value(attrs, :in_reply_to),
          value(attrs, :attempt),
          output_key,
          Map.delete(timeline_attrs, :role),
          []
        )

      proactive_key = value(attrs, :proactive_key) ->
        proactive_key = proactive_output_key(proactive_key, attrs)
        store().append_proactive(profile_id, proactive_key, timeline_attrs, [])

      true ->
        case store().append(profile_id, timeline_attrs, []) do
          {:ok, row} -> {:ok, {:created, row}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp client_output?(attrs) do
    is_binary(value(attrs, :in_reply_to)) and value(attrs, :in_reply_to) != "" and
      is_integer(value(attrs, :attempt)) and value(attrs, :attempt) > 0
  end

  defp proactive_output_key(key, attrs) do
    case value(attrs, :proactive_part_id) do
      nil -> key
      part_id -> "#{key}:#{part_id}"
    end
  end

  defp text_output_key(text), do: "text:" <> content_digest(text)
  defp media_output_key(ref), do: "media:" <> value(ref, :ref)

  defp content_digest(content) do
    :crypto.hash(:sha256, content)
    |> Base.url_encode64(padding: false)
  end

  defp deliver_persisted_text(:existing, _profile, _text, _row, _opts), do: :ok

  defp deliver_persisted_text(:created, profile, text, row, opts) do
    _ = emit_after_commit(profile, text_done(turn_id_from_opts(opts), row.server_seq, text))
    _ = maybe_schedule_proactive_push(profile, row.server_seq, opts)
    _ = schedule_unfurl(profile, row.server_seq, text)
    :ok
  end

  defp deliver_persisted_media(:existing, _profile, _media, _ref, _row, _opts), do: :ok

  defp deliver_persisted_media(:created, profile, media, ref, row, opts) do
    _ = emit_media_after_commit(profile, row.server_seq, media, ref)
    _ = maybe_schedule_proactive_push(profile, row.server_seq, opts)
    _ = schedule_unfurl(profile, row.server_seq, value(media, :caption) || "")
    :ok
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

  defp turn_id_from_opts(opts), do: Keyword.get(opts, :turn_id, new_turn_id())

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

  defp launch_unfurl(task, opts) do
    launcher =
      Keyword.get(opts, :unfurl_launcher) ||
        Application.get_env(:fermix_channels, :mobile_unfurl_launcher) ||
        (&default_unfurl_launcher/1)

    case launcher.(task) do
      :ok -> :ok
      {:ok, _pid} -> :ok
      {:error, reason} -> log_unfurl_error(:launch_failed, reason)
      other -> log_unfurl_error(:invalid_launcher_result, other)
    end
  end

  defp default_unfurl_launcher(task) do
    Task.Supervisor.start_child(FermixCore.TaskSupervisor, task)
  end

  defp resolve_unfurls(profile_id, server_seq, text, opts) do
    thumbnail_store = thumbnail_store(profile_id, server_seq, opts)

    result =
      case unfurl_resolver(opts) do
        nil -> Unfurl.resolve(text, store_thumbnail: thumbnail_store)
        resolver -> resolver.(text, thumbnail_store)
      end

    handle_unfurl_result(result, profile_id, server_seq, opts)
  end

  defp unfurl_resolver(opts) do
    override = Keyword.get(opts, :unfurl) || Application.get_env(:fermix_channels, :mobile_unfurl)

    injected(override, 2, :mobile_unfurl)
  end

  defp handle_unfurl_result({:ok, previews, warnings}, profile_id, server_seq, opts)
       when is_list(previews) and is_list(warnings) do
    Enum.each(previews, &emit_link_preview(profile_id, server_seq, &1, opts))
    Enum.each(warnings, &log_unfurl_error(:resolution_warning, &1))
    :ok
  end

  defp handle_unfurl_result({:error, reason}, _profile_id, _server_seq, _opts),
    do: log_unfurl_error(:resolution_failed, reason)

  defp handle_unfurl_result(other, _profile_id, _server_seq, _opts),
    do: log_unfurl_error(:invalid_resolver_result, other)

  defp emit_link_preview(profile_id, server_seq, preview, opts) do
    event = %{
      "t" => "link_preview",
      "in_reply_to" => server_seq,
      "url" => value(preview, :url),
      "site" => value(preview, :site),
      "title" => value(preview, :title),
      "description" => value(preview, :description),
      "image_ref" => value(preview, :image_ref)
    }

    case emit_unfurl_event(profile_id, event, opts) do
      :ok -> :ok
      {:error, reason} -> log_unfurl_error(:fanout_failed, reason)
    end
  end

  defp emit_unfurl_event(profile_id, event, opts) do
    case Keyword.get(opts, :event_sink) do
      sink when is_function(sink, 2) -> sink.({:profile, profile_id}, event)
      nil -> emit(profile_id, event)
    end
  end

  # A thumbnail ref is only fetchable once it sits in the durable row's
  # media_refs: `media_fetch` authorizes every ref against that row. Storing the
  # blob and attaching it are therefore one step, finished before the
  # `link_preview` naming the ref is fanned out.
  defp thumbnail_store(profile_id, server_seq, opts) do
    writer = thumbnail_writer(opts)

    fn bytes, mime ->
      store_and_attach_thumbnail(writer, {profile_id, server_seq}, bytes, mime, opts)
    end
  end

  defp thumbnail_writer(opts) do
    override = injected(Keyword.get(opts, :thumbnail_store), 2, :thumbnail_store)

    override || (&store_unfurl_thumbnail/2)
  end

  defp store_and_attach_thumbnail(writer, target, bytes, mime, opts)
       when is_binary(bytes) and is_binary(mime) do
    with {:ok, ref} when is_binary(ref) <- writer.(bytes, mime),
         descriptor = thumbnail_descriptor(ref, bytes, mime),
         {:ok, _row} <- attach_thumbnail(target, descriptor, opts) do
      {:ok, ref}
    end
  end

  defp thumbnail_descriptor(ref, bytes, mime) do
    %{
      "ref" => ref,
      "sha256" => ref,
      "kind" => "image",
      "mime" => mime,
      "size_bytes" => byte_size(bytes)
    }
  end

  defp attach_thumbnail({profile_id, server_seq}, descriptor, opts) do
    store_module = Keyword.get(opts, :store, store())

    store_module.attach_timeline_media(
      profile_id,
      server_seq,
      descriptor,
      Keyword.get(opts, :store_opts, [])
    )
  end

  defp store_unfurl_thumbnail(bytes, mime) do
    MediaStore.put_bytes(MediaStore, bytes, %{kind: :image, mime_type: mime})
  end

  defp log_unfurl_error(stage, reason) do
    Logger.warning("mobile unfurl #{stage}: #{inspect(reason)}")
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

  defp store, do: Application.get_env(:fermix_channels, :mobile_store, Store)

  defp emit(profile_id, event) do
    case Application.get_env(:fermix_channels, :mobile_event_sink) do
      nil ->
        _count = DeviceRegistry.send_profile_event(profile_id, event)
        :ok

      sink when is_function(sink, 2) ->
        sink.(profile_id, event)

      other ->
        raise ArgumentError,
              ":mobile_event_sink must be a 2-arity function, got: #{inspect(other)}"
    end
  end

  defp emit_open(message, turn_id, text) do
    with :ok <- emit(message.chat_id, turn_started(message, turn_id)) do
      emit_delta(message.chat_id, turn_id, text)
    end
  end

  defp turn_started(message, turn_id) do
    %{
      "t" => "turn_started",
      "profile_id" => message.chat_id,
      "turn_id" => turn_id,
      "in_reply_to" => client_message_id(message)
    }
  end

  defp emit_delta(_profile, _turn_id, ""), do: :ok

  defp emit_delta(profile, turn_id, text),
    do: emit(profile, %{"t" => "text_delta", "turn_id" => turn_id, "text" => text})

  defp text_done(turn_id, seq, text),
    do: %{"t" => "text_done", "turn_id" => turn_id, "server_seq" => seq, "text" => text}

  defp tool_event(turn_id, {:tool_start, tool}),
    do: %{"t" => "tool_event", "turn_id" => turn_id, "tool" => tool, "phase" => "start"}

  defp tool_event(turn_id, {:tool_finish, tool, detail}),
    do: %{
      "t" => "tool_event",
      "turn_id" => turn_id,
      "tool" => tool,
      "phase" => "stop",
      "detail" => inspect(detail)
    }

  defp tool_event(turn_id, event),
    do: %{
      "t" => "tool_event",
      "turn_id" => turn_id,
      "tool" => "unknown",
      "phase" => "stop",
      "detail" => inspect(event)
    }

  defp turn_error(turn_id, reason),
    do: %{
      "t" => "turn_error",
      "turn_id" => turn_id,
      "code" => error_code(reason),
      "message" => error_message(reason)
    }

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "turn_failed"
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)

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

  defp suffix(prior, text) do
    if String.starts_with?(text, prior) do
      binary_part(text, byte_size(prior), byte_size(text) - byte_size(prior))
    else
      text
    end
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

  defp complete_request(message) do
    case store().complete_client_request(
           message.chat_id,
           client_message_id(message),
           request_attempt(message),
           %{},
           []
         ) do
      {:ok, request} -> {:ok, request}
      {:error, :not_found} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp fail_request(message, reason) do
    case store().fail_client_request(
           message.chat_id,
           client_message_id(message),
           request_attempt(message),
           %{error: inspect(reason)},
           []
         ) do
      {:ok, _request} -> :ok
      {:error, :not_found} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp fail_and_emit(message, turn_id, reason) do
    with :ok <- fail_request(message, reason) do
      emit(message.chat_id, turn_error(turn_id, reason))
    end
  end

  defp settle_turn_and_notify(message, :completed) do
    case complete_request(message) do
      {:ok, request} -> schedule_request_push(message.chat_id, request)
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_emit_and_notify(message, turn_id, reason) do
    fail_and_emit(message, turn_id, reason)
  end

  defp schedule_request_push(profile_id, request) do
    case value(request, :result_server_seq) do
      server_seq when is_integer(server_seq) and server_seq > 0 ->
        schedule_push(profile_id, server_seq)

      _none ->
        :ok
    end
  end

  defp request_attempt(message), do: value(message.metadata, :mobile_attempt)

  defp approval_routes(:sandbox, token),
    do: {"/confirm #{token}", "/deny #{token}", @sandbox_ttl_s}

  defp approval_routes(:soul, token),
    do: {"/soul apply #{token}", "/soul deny #{token}", @soul_ttl_s}

  defp scrub_command(text, command), do: String.replace(text, command, "", global: true)

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
