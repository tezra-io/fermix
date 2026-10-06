defmodule FermixChannels.Channels.IMessage do
  @moduledoc """
  iMessage channel adapter (docs/design/MILESTONE_54_IMESSAGE_CHANNEL.md).

  Nothing in the BEAM opens `chat.db` or sends an Apple Event: the signed
  Fermix Messages helper holds both grants and the confirmed recipient policy,
  and this adapter speaks to it through `IMessage.Helper` (production:
  `IMessage.Port`). `IMessage.Listener` turns the helper's admitted rows into
  gateway messages with `parse_batch/3`.

  Outbound is plain text (`Outbound.Plain`), split at 4,000 rendered
  characters and sent strictly in order, one `send.text` per chunk. Each send
  carries an idempotency key the helper's ledger answers on a repeat, so a
  retry of the same delivery never sends twice. The helper reports one of three
  dispositions per send (§8.2): `recorded` is delivered, `failed` names a
  pre-dispatch class and maps onto a permanent delivery error, and `uncertain`
  maps onto `{:transport, :timeout}` — the real send may have gone, so the same
  key is what a retry carries, and the ledger answers it without sending.

  No typing, no drafts, no reactions, no ephemeral messages: the Messages
  dictionary offers none of them (§21), so they are declared absent.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Channels.IMessage.Port, as: HelperPort
  alias FermixChannels.Channels.IMessage.Protocol
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Outbound.Plain
  alias FermixChannels.Outbound.Splitter
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Config
  alias FermixCore.IMessage.Control
  alias FermixCore.Telemetry

  # A Fermix readability ceiling, as for Signal (CHANNEL_LONGFORM_PRESENTATION
  # §3.1): iMessage has no practical text cap of its own.
  @max_message_length 4_000
  # The helper enforces the same cap while copying (§8.3).
  @max_media_bytes 100 * 1_024 * 1_024
  # The helper's own budgets: osascript 20 s plus 8 s of verification for a
  # text, plus the staging copy for a file, plus a bounded conversion for a
  # fetch. The engine waits a little longer than each.
  @send_text_timeout_ms 40_000
  @send_file_timeout_ms 60_000
  @fetch_timeout_ms 45_000
  @diagnostic_max 500

  @unavailable_kinds [
    :helper_unavailable,
    :not_initialized,
    :protocol_mismatch,
    :permission_denied,
    :db_missing,
    :db_unreadable,
    :db_schema_unexpected,
    :policy_absent,
    :policy_unconfirmed,
    :policy_refused,
    :owner_not_self,
    :owner_is_this_mac,
    :not_signed_in,
    :no_user_session,
    :automation_refused
  ]
  @rejected_kinds [:chat_not_found, :service_not_imessage, :policy_violation]
  @malformed_kinds [:path_refused, :attachment_too_large, :attachment_not_admitted]
  @timeout_kinds [:send_timeout, :request_timeout]
  @converted_images ["image/heic", "image/heif"]
  # The probe's gates in the order a person fixes them (§10.1): the field, the
  # one value that opens it, and the class it reports otherwise (`:db` and
  # `:policy` name the class by the value the helper reported). After them,
  # the owner gate (`owner_gate/2`).
  @gates [
    {:user_session, true, :no_user_session},
    {:full_disk_access, :granted, {:permission_denied, :full_disk_access}},
    {:db, :readable, :db},
    {:policy, :confirmed, :policy},
    {:automation, :granted, {:permission_denied, :automation}},
    {:signed_in, true, :not_signed_in}
  ]

  @type posture :: :dedicated_account | :own_account

  @typedoc "Who the channel may talk to, from config: the owner, and owner ∪ guests."
  @type recipients :: %{owner: String.t(), handles: [String.t()]}

  @typedoc """
  The recipients plus the account posture the helper derived when it confirmed
  them (`policy.get`); admission and the row mapping read it.
  """
  @type policy :: %{posture: posture(), owner: String.t(), handles: [String.t()]}

  @typedoc "The helper an inbound message came through, carried so replies use it too."
  @type routing :: %{optional(:helper) => module(), optional(:server) => atom()}

  @type gate_class ::
          :no_user_session
          | {:permission_denied, :full_disk_access | :automation}
          | :db_missing
          | :db_unreadable
          | :db_schema_unexpected
          | :policy_absent
          | :policy_unconfirmed
          | :not_signed_in
          | :owner_is_this_mac

  # --- Transport and capabilities -------------------------------------------------

  @impl true
  @spec parse_webhook(map()) :: {:error, :unsupported_transport}
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @impl true
  @spec verify_webhook(Plug.Conn.t()) :: {:error, :unsupported_transport}
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  @spec stream_capability() :: :none
  def stream_capability, do: :none

  @impl true
  @spec reaction_capability() :: :none
  def reaction_capability, do: :none

  # --- Inbound mapping (§7.5) -------------------------------------------------------

  @doc """
  Maps one admitted helper row onto a `Gateway.Message`. `metadata.user_id` is
  the counterpart handle in the dedicated posture and the owner's handle in the
  own posture; `Gateway.Authorizer` decides trust from it unchanged.
  """
  @spec parse_row(map(), policy(), routing()) ::
          {:ok, Message.t()} | {:error, {:malformed_row, atom()}}
  def parse_row(row, policy, routing \\ %{})
      when is_map(row) and is_map(policy) and is_map(routing) do
    {result, duration_us} = Telemetry.timed_us(fn -> build_message(row, policy, routing) end)
    ChannelTelemetry.emit_parse(:imessage, parse_status(result), duration_us)
    log_decode_error(result)
    result
  end

  @doc """
  Maps a batch of admitted rows, dropping (and logging) any row the helper sent
  malformed, and emits one inbound message event for the batch.
  """
  @spec parse_batch([map()], policy(), routing()) :: [Message.t()]
  def parse_batch(rows, policy, routing) when is_list(rows) and is_map(policy) do
    {messages, duration_us} =
      Telemetry.timed_us(fn -> Enum.flat_map(rows, &parsed(&1, policy, routing)) end)

    if messages != [] do
      ChannelTelemetry.emit_message(:imessage, :inbound, length(messages), duration_us)
    end

    messages
  end

  defp parsed(row, policy, routing) do
    case parse_row(row, policy, routing) do
      {:ok, message} ->
        [message]

      {:error, reason} ->
        Logger.error("iMessage row #{inspect(row["rowid"])} dropped: #{inspect(reason)}")
        []
    end
  end

  defp build_message(row, policy, routing) do
    with {:ok, guid} <- row_guid(row),
         {:ok, rowid} <- row_rowid(row),
         {:ok, counterpart} <- counterpart(row, policy) do
      {:ok,
       Message.new!(%{
         id: guid,
         content: row_text(row),
         sender: counterpart,
         channel: "imessage",
         chat_id: counterpart,
         reply_target: counterpart,
         metadata: metadata(row, rowid, policy, counterpart, routing),
         attachments: attachments(row, guid)
       })}
    end
  end

  defp metadata(row, rowid, policy, counterpart, routing) do
    %{
      user_id: counterpart,
      sender_id: counterpart,
      chat_type: "private",
      service: "iMessage",
      guid: row["guid"],
      rowid: rowid,
      date: row["date"],
      reply_to_guid: row["reply_to_guid"],
      posture: policy.posture,
      decode_error: row["decode_error"]
    }
    |> put_present(:imessage_helper, Map.get(routing, :helper))
    |> put_present(:imessage_server, routing_server(routing))
  end

  # Only a registered name rides in message metadata, never a pid.
  defp routing_server(%{server: server}) when is_atom(server), do: server
  defp routing_server(_routing), do: nil

  defp row_guid(row) do
    case row["guid"] do
      guid when is_binary(guid) and guid != "" -> {:ok, guid}
      _missing -> {:error, {:malformed_row, :guid}}
    end
  end

  defp row_rowid(row) do
    case row["rowid"] do
      rowid when is_integer(rowid) and rowid >= 0 -> {:ok, rowid}
      _missing -> {:error, {:malformed_row, :rowid}}
    end
  end

  defp counterpart(_row, %{posture: :own_account, owner: owner}), do: {:ok, owner}

  defp counterpart(row, %{posture: :dedicated_account}) do
    case Protocol.normalize_handle(nested(row, "sender", "handle")) do
      {:ok, handle} -> {:ok, handle}
      {:error, :invalid_handle} -> {:error, {:malformed_row, :handle}}
    end
  end

  defp row_text(row) do
    case row["text"] do
      text when is_binary(text) -> text
      _none -> ""
    end
  end

  defp attachments(row, guid) do
    row
    |> Map.get("attachments")
    |> List.wrap()
    |> Enum.flat_map(&attachment(&1, guid))
  end

  defp attachment(%{"index" => index} = item, guid) when is_integer(index) and index >= 0 do
    mime = item["mime"]

    [
      %{
        kind: attachment_kind(mime),
        file_id: {guid, index},
        mime_type: mime,
        size_bytes: item["bytes"]
      }
    ]
  end

  defp attachment(item, guid) do
    Logger.error("iMessage message #{guid} carried a malformed attachment: #{bounded(item)}")
    []
  end

  defp attachment_kind("audio/" <> _rest), do: :audio
  defp attachment_kind("image/" <> _rest), do: :image
  defp attachment_kind(_mime), do: :file

  defp parse_status({:ok, %Message{metadata: %{decode_error: class}}}) when is_binary(class),
    do: {:error, :decode_error}

  defp parse_status(result), do: result

  defp log_decode_error({:ok, %Message{id: guid, metadata: %{decode_error: class}}})
       when is_binary(class) do
    Logger.warning(
      "iMessage #{guid} could not be decoded (#{class}); delivered as an empty message"
    )
  end

  defp log_decode_error(_result), do: :ok

  # --- Outbound text (§8.1, §8.2) ---------------------------------------------------

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(recipient, text, opts \\ [])
      when is_binary(recipient) and is_binary(text) and is_list(opts) do
    with {:ok, to} <- destination(recipient) do
      text
      |> render_chunks()
      |> send_chunks(to, key_base(opts) <> ":text", runtime(opts, %{}))
    end
  end

  # The ladder walks the model's Markdown, every candidate is measured through
  # the plain renderer, and each emitted chunk is rendered for the wire.
  defp render_chunks(text) do
    {chunks, duration_us} =
      Telemetry.timed_us(fn ->
        text
        |> Splitter.split(limit: @max_message_length, measure: &Plain.rendered_length/1)
        |> Enum.map(&Plain.render/1)
      end)

    ChannelTelemetry.emit_render(:imessage, :ok, duration_us)
    chunks
  end

  # Strictly sequential: the first failure stops the remaining chunks.
  defp send_chunks(chunks, to, key, runtime) do
    chunks
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {chunk, index}, :ok ->
      case send_chunk(runtime, to, chunk, "#{key}:#{index}") do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp send_chunk(runtime, to, chunk, key) do
    params = %{"to" => to, "text" => chunk, "idempotency_key" => key}

    {result, duration_us} =
      Telemetry.timed_us(fn ->
        runtime.helper.call(runtime.server, "send.text", params, @send_text_timeout_ms)
      end)

    send_outcome(result, key, duration_us)
  end

  # One recorded message is one outbound event, its duration including the
  # helper's verification wait (§13).
  defp send_outcome({:ok, %{"disposition" => "recorded"}}, _key, duration_us) do
    ChannelTelemetry.emit_message(:imessage, :outbound, 1, duration_us)
    :ok
  end

  defp send_outcome({:ok, %{"disposition" => "uncertain"}}, key, _duration_us) do
    Logger.warning(
      "iMessage send #{key} is uncertain: Messages recorded no outgoing row, and the send " <>
        "may still have gone; it is not re-sent"
    )

    {:error, {:transport, :timeout}}
  end

  defp send_outcome({:ok, %{"disposition" => "failed", "class" => class}}, key, _duration_us)
       when is_binary(class) do
    Logger.warning("iMessage send #{key} failed before dispatch: #{class}")
    {:error, failed_class(class)}
  end

  defp send_outcome({:ok, result}, key, _duration_us) do
    Logger.error("iMessage send #{key} returned an unknown disposition: #{bounded(result)}")
    {:error, {:unexpected_delivery_result, :invalid_contract}}
  end

  defp send_outcome({:error, {kind, message, _data}}, key, _duration_us) do
    Logger.warning("iMessage send #{key} refused (#{kind}): #{bounded(message)}")
    {:error, delivery_error(kind)}
  end

  defp failed_class(class) do
    case Protocol.decode_error_kind(class) do
      {:ok, kind} -> delivery_error(kind)
      {:error, {:unknown_error_kind, _class}} -> {:unexpected_delivery_result, :invalid_contract}
    end
  end

  # §8.4: the helper's closed kinds onto the closed delivery vocabulary. `busy`
  # is refused before dispatch, the same nature as a pool checkout that never
  # got a slot, so it is the one transport kind safe to try again.
  defp delivery_error(kind) when kind in @unavailable_kinds,
    do: {:permanent, :adapter_unavailable}

  defp delivery_error(kind) when kind in @rejected_kinds, do: {:permanent, :remote_rejected}
  defp delivery_error(kind) when kind in @malformed_kinds, do: {:permanent, :malformed_request}
  defp delivery_error(kind) when kind in @timeout_kinds, do: {:transport, :timeout}
  defp delivery_error(:busy), do: {:transport, :pool_unavailable}
  defp delivery_error(_protocol_error), do: {:unexpected_delivery_result, :invalid_contract}

  # The key a repeated delivery must carry for the helper's ledger to answer it
  # (§8.2): a proactive delivery's key is stable across its durable retries, a
  # turn reply's is its turn and attempt, and anything else is sent once.
  defp key_base(opts) do
    case {present(opts, :proactive_key), present(opts, :turn_id)} do
      {nil, nil} -> "once:" <> uuid4()
      {nil, turn_id} -> "turn:#{turn_id}:#{Keyword.get(opts, :attempt) || 0}"
      {key, _turn_id} -> "proactive:#{key}:#{present(opts, :proactive_part_id) || "main"}"
    end
  end

  defp destination(recipient) do
    case Protocol.normalize_handle(recipient) do
      {:ok, handle} ->
        {:ok, handle}

      {:error, :invalid_handle} ->
        Logger.warning("iMessage send refused: #{inspect(recipient)} is not a handle")
        {:error, {:permanent, :invalid_destination}}
    end
  end

  # --- Outbound media (§8.3) ---------------------------------------------------------

  @impl true
  @spec send_media(String.t(), FermixChannels.Gateway.Channel.media_part()) ::
          :ok | {:error, term()}
  @spec send_media(
          String.t(),
          FermixChannels.Gateway.Channel.media_part(),
          FermixChannels.Gateway.Channel.send_opts()
        ) :: :ok | {:error, term()}
  def send_media(recipient, media_part, opts \\ [])
      when is_binary(recipient) and is_map(media_part) and is_list(opts) do
    with {:ok, to} <- destination(recipient),
         {:ok, claim} <- claim_media(to, media_part) do
      send_claimed_media(claim, to, media_part, opts)
    end
  end

  defp claim_media(to, media_part) do
    case Idempotency.claim_outbound_media(:imessage, to, media_part) do
      {:ok, claim} -> {:ok, claim}
      {:error, reason} -> media_refused(reason)
    end
  end

  defp send_claimed_media(:duplicate, _to, _media_part, _opts), do: :ok

  defp send_claimed_media({:fresh, claim}, to, media_part, opts) do
    case deliver_media(to, media_part, runtime(opts, %{}), key_base(opts)) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        :ok = Idempotency.release_outbound_media_claim(claim)
        error
    end
  end

  # The outbox entry exists only for the length of the send: the helper copies
  # it into its own staging directory before it answers.
  defp deliver_media(to, media_part, runtime, key) do
    with :ok <- validate_media(media_part),
         {:ok, home} <- helper_home(runtime),
         {:ok, staged} <- stage_outbox(home, media_part) do
      try do
        send_staged(runtime, to, media_part, staged, key)
      after
        unstage(staged)
      end
    end
  end

  defp send_staged(runtime, to, media_part, staged, key) do
    file_key = key <> ":media"

    params = %{
      "to" => to,
      "path" => staged.path,
      "mime" => Map.get(media_part, :mime_type) || "application/octet-stream",
      "idempotency_key" => file_key
    }

    {result, duration_us} =
      Telemetry.timed_us(fn ->
        runtime.helper.call(runtime.server, "send.file", params, @send_file_timeout_ms)
      end)

    with :ok <- send_outcome(result, file_key, duration_us) do
      send_caption(runtime, to, media_part, key)
    end
  end

  # `send.file` carries no caption, so a captioned part follows its file as
  # ordinary text, keyed with the same delivery.
  defp send_caption(runtime, to, %{caption: caption}, key)
       when is_binary(caption) and caption != "" do
    caption
    |> render_chunks()
    |> send_chunks(to, key <> ":caption", runtime)
  end

  defp send_caption(_runtime, _to, _media_part, _key), do: :ok

  defp validate_media(%{path: path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_media_bytes ->
        :ok

      {:ok, %{type: :regular, size: size}} ->
        media_refused({:byte_cap_exceeded, size, @max_media_bytes})

      {:ok, %{type: type}} ->
        media_refused({:not_a_regular_file, type})

      {:error, reason} ->
        media_refused({:unreadable, reason})
    end
  end

  defp validate_media(_media_part), do: media_refused(:invalid_media_part)

  defp media_refused(reason) do
    Logger.warning("iMessage media refused: #{bounded(reason)}")
    {:error, {:permanent, :malformed_request}}
  end

  defp stage_outbox(home, media_part) do
    root = Path.join(home, "imessage")
    outbox = Path.join(root, "outbox")
    dir = Path.join(outbox, uuid4())
    path = Path.join(dir, outbox_name(media_part))

    with :ok <- private_dir(root),
         :ok <- private_dir(outbox),
         :ok <- private_dir(dir),
         :ok <- File.cp(media_part.path, path) do
      {:ok, %{dir: dir, path: path}}
    else
      {:error, reason} ->
        Logger.error("iMessage could not stage media in its outbox: #{inspect(reason)}")
        {:error, {:permanent, :adapter_unavailable}}
    end
  end

  # Removes exactly the two things `stage_outbox/2` created, never a tree.
  defp unstage(%{dir: dir, path: path}) do
    log_cleanup(remove_file(path), "file")
    log_cleanup(File.rmdir(dir), "entry")
  end

  defp log_cleanup(:ok, _what), do: :ok

  defp log_cleanup({:error, reason}, what),
    do: Logger.error("iMessage outbox cleanup failed for a staged #{what}: #{inspect(reason)}")

  defp remove_file(path) do
    case File.rm(path) do
      result when result in [:ok, {:error, :enoent}] -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp private_dir(dir) do
    with :ok <- File.mkdir_p(dir) do
      File.chmod(dir, 0o700)
    end
  end

  defp outbox_name(media_part) do
    name =
      (Map.get(media_part, :filename) || Path.basename(media_part.path))
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]/u, "_")
      |> String.trim_leading(".")
      |> String.slice(0, 128)

    if name == "", do: "attachment", else: name
  end

  defp helper_home(runtime) do
    case runtime.helper.home(runtime.server) do
      {:ok, home} when is_binary(home) ->
        {:ok, home}

      {:error, {kind, message, _data}} ->
        Logger.warning("iMessage media refused (#{kind}): #{bounded(message)}")
        {:error, delivery_error(kind)}
    end
  end

  # --- Reply closures -----------------------------------------------------------

  @impl true
  @spec build_text_reply(FermixChannels.Gateway.Channel.message()) ::
          (String.t() -> :ok | {:error, term()})
  def build_text_reply(%Message{reply_target: reply_target, metadata: metadata}) do
    opts = routing_opts(metadata)
    fn text -> send_message(reply_target, text, opts) end
  end

  @impl true
  @spec build_media_reply(FermixChannels.Gateway.Channel.message()) ::
          (FermixChannels.Gateway.Channel.media_part() -> :ok | {:error, term()})
  def build_media_reply(%Message{reply_target: reply_target, metadata: metadata}) do
    opts = routing_opts(metadata)
    fn media_part -> send_media(reply_target, media_part, opts) end
  end

  # --- Inbound attachments (§8.3) ----------------------------------------------------

  @doc """
  Asks the helper to copy one attachment of an admitted message into
  `FERMIX_HOME/imessage/inbox/<guid>/` (converting voice memos and HEIC) and
  answers that path. The gateway deletes it after the turn; a path outside the
  message's own inbox entry is refused, so nothing else is ever deleted.
  """
  @impl true
  @spec download_attachment(FermixChannels.Gateway.Channel.message(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def download_attachment(%Message{metadata: metadata}, attachment) when is_map(attachment) do
    runtime = runtime([], metadata)

    with {:ok, {guid, index}} <- attachment_ref(attachment),
         {:ok, path} <- fetch_attachment(runtime, guid, index, convert?(attachment)),
         {:ok, home} <- fetch_home(runtime) do
      inbox_path(path, home, guid)
    end
  end

  defp attachment_ref(attachment) do
    case Map.get(attachment, :file_id) do
      {guid, index} when is_binary(guid) and is_integer(index) and index >= 0 ->
        if safe_segment?(guid),
          do: {:ok, {guid, index}},
          else: {:error, :invalid_attachment_reference}

      _other ->
        {:error, :missing_attachment_reference}
    end
  end

  defp safe_segment?(guid),
    do: guid not in ["", ".", ".."] and not String.contains?(guid, ["/", <<0>>])

  defp convert?(attachment) do
    case Map.get(attachment, :mime_type) do
      "audio/" <> _rest -> true
      mime -> mime in @converted_images
    end
  end

  defp fetch_attachment(runtime, guid, index, convert?) do
    params = %{"message_guid" => guid, "index" => index, "convert" => convert?}

    case runtime.helper.call(runtime.server, "attachment.fetch", params, @fetch_timeout_ms) do
      {:ok, %{"path" => path}} when is_binary(path) -> {:ok, path}
      {:ok, other} -> {:error, {:protocol_error, bounded(other)}}
      {:error, {kind, message, _data}} -> {:error, {kind, message}}
    end
  end

  defp fetch_home(runtime) do
    case runtime.helper.home(runtime.server) do
      {:ok, home} -> {:ok, home}
      {:error, {kind, message, _data}} -> {:error, {kind, message}}
    end
  end

  defp inbox_path(path, home, guid) do
    entry = Path.join([Path.expand(home), "imessage", "inbox", guid])
    expanded = Path.expand(path)

    cond do
      Path.dirname(expanded) != entry -> {:error, {:attachment_path_refused, :outside_inbox}}
      not regular_file?(expanded) -> {:error, {:attachment_path_refused, :not_a_regular_file}}
      true -> {:ok, expanded}
    end
  end

  defp regular_file?(path), do: match?({:ok, %{type: :regular}}, File.lstat(path))

  # --- Health (§10.1, §10.4) -----------------------------------------------------

  @doc """
  Health is the one-shot `probe` (`FermixCore.IMessage.Control`), never the
  serving helper: Doctor asks from a tree-less CLI process where no Port runs,
  and the daemon's own answer must be the same one, so there is one path.
  The owner it checks against the account's own aliases is the saved one.
  `control:`, `home:` and `owner:` are test seams.
  """
  @impl true
  @spec health_check(keyword()) :: FermixChannels.Gateway.Channel.health_result()
  def health_check(opts \\ []) when is_list(opts) do
    control = Keyword.get(opts, :control, Control)
    owner = Keyword.get_lazy(opts, :owner, &configured_owner/0)
    started = System.monotonic_time(:millisecond)

    case control.probe(Keyword.take(opts, [:home])) do
      {:ok, probe} ->
        health(probe_gate(probe, owner), System.monotonic_time(:millisecond) - started)

      {:error, reason} ->
        {:error, control_error(reason)}
    end
  end

  # An owner that is missing or unparseable is the config's own refusal
  # (`recipients_from_config/0`); the owner gate has nothing to compare then.
  defp configured_owner do
    case owner() do
      {:ok, owner} -> owner
      {:error, _not_configured} -> nil
    end
  end

  defp control_error(:not_installed), do: {:helper_missing, "Fermix Messages is not installed"}

  defp control_error(:timeout),
    do: {:helper_unavailable, "Fermix Messages did not answer the probe in time"}

  defp control_error({:spawn_failed, reason}),
    do: {:helper_unavailable, "Fermix Messages could not be started: #{inspect(reason)}"}

  defp control_error({:helper_exit, class}),
    do: {:helper_exit, "Fermix Messages exited before answering: #{inspect(class)}"}

  defp control_error({:helper_error, kind, message}), do: {kind, message}

  defp control_error({:helper_protocol, reason}),
    do: {:protocol_error, "Fermix Messages answered outside the protocol: #{inspect(reason)}"}

  defp health(:ok, latency_ms) do
    detail =
      "Fermix Messages is answering with every permission granted and the recipients confirmed"

    {:ok, %{detail: detail, latency_ms: latency_ms}}
  end

  defp health({:error, class}, _latency_ms), do: {:error, {class, gate_detail(class)}}

  @doc """
  The first thing a typed probe (`FermixCore.IMessage.Control.probe/0`,
  `Control.decode_probe/1`) says is missing, in the order a person fixes them,
  or `:ok`. The Listener opens no subscription and `health_check/1` is red
  until this is `:ok`.

  The last gate is the helper's own rule for the account: an `owner` among the
  signed-in account's own aliases means Messages on this Mac is signed in as
  the owner (`:owner_is_this_mac`), which the helper refuses until the
  own-account mode is supported. A `nil` owner or unknown aliases leave it open.
  """
  @spec probe_gate(Control.probe(), String.t() | nil) :: :ok | {:error, gate_class()}
  def probe_gate(probe, owner) when is_map(probe) and (is_binary(owner) or is_nil(owner)) do
    first_closed =
      Enum.find_value(@gates, :ok, fn {field, open, class} ->
        gate(Map.get(probe, field), open, class)
      end)

    with :ok <- first_closed, do: owner_gate(Map.get(probe, :self_aliases), owner)
  end

  defp owner_gate(aliases, owner) when is_list(aliases) and is_binary(owner) do
    own? = Enum.any?(aliases, &(Protocol.normalize_handle(&1) == {:ok, owner}))
    if own?, do: {:error, :owner_is_this_mac}, else: :ok
  end

  defp owner_gate(_aliases, _owner), do: :ok

  defp gate(open, open, _class), do: nil
  defp gate(value, _open, :db), do: {:error, db_class(value)}
  defp gate(value, _open, :policy), do: {:error, policy_class(value)}
  defp gate(_value, _open, class), do: {:error, class}

  defp db_class(:missing), do: :db_missing
  defp db_class(:schema_unexpected), do: :db_schema_unexpected
  defp db_class(_unreadable), do: :db_unreadable

  defp policy_class(:unconfirmed), do: :policy_unconfirmed
  defp policy_class(_absent), do: :policy_absent

  defp gate_detail(:no_user_session),
    do: "iMessage needs Fermix running in your logged-in session"

  defp gate_detail({:permission_denied, :full_disk_access}),
    do:
      "Needs Full Disk Access: grant it to Fermix Messages in System Settings, Privacy & Security, Full Disk Access"

  defp gate_detail(:db_missing), do: "Messages has no database on this Mac"
  defp gate_detail(:db_unreadable), do: "Fermix Messages cannot read the Messages database"

  defp gate_detail(:db_schema_unexpected),
    do:
      "The Messages database changed shape after a macOS update; Fermix Messages needs an update"

  defp gate_detail(class) when class in [:policy_absent, :policy_unconfirmed],
    do: "Awaiting confirmation: confirm who Fermix may message in Settings, System, Permissions"

  defp gate_detail({:permission_denied, :automation}),
    do: "Needs Messages automation: grant Automation, Messages to Fermix Messages"

  defp gate_detail(:not_signed_in), do: "Messages is not signed in on this Mac"

  defp gate_detail(:owner_is_this_mac),
    do: "Sign Messages in with a separate Apple ID for Fermix"

  # --- Config ---------------------------------------------------------------------

  @doc """
  The channel's recipients from `[fermix_channels.imessage]`: the owner's
  normalized handle, and owner ∪ allowed senders (an empty allow list means no
  guests, never no owner). The account posture is not config: the Listener
  reads the one the helper derived (`policy.get`).
  """
  @spec recipients_from_config() :: {:ok, recipients()} | {:error, term()}
  def recipients_from_config do
    with {:ok, _config} <- Config.channel(:imessage),
         {:ok, owner} <- owner(),
         {:ok, guests} <- normalize_all(Config.channel_ingress_user_ids(:imessage)) do
      {:ok, %{owner: owner, handles: Enum.uniq([owner | guests])}}
    end
  end

  defp owner do
    case Config.channel_explicit_owner_user_id(:imessage) do
      nil -> {:error, :owner_not_configured}
      raw -> normalize_configured(raw)
    end
  end

  defp normalize_all(raws) do
    Enum.reduce_while(raws, {:ok, []}, fn raw, {:ok, acc} ->
      case normalize_configured(raw) do
        {:ok, handle} -> {:cont, {:ok, acc ++ [handle]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_configured(raw) do
    case Protocol.normalize_handle(raw) do
      {:ok, handle} -> {:ok, handle}
      {:error, :invalid_handle} -> {:error, {:invalid_handle, raw}}
    end
  end

  # --- Shared ---------------------------------------------------------------------

  # The helper a call goes through: explicit options (tests, the bench), then
  # the inbound message's routing, then the channel's own Port.
  defp runtime(opts, metadata) do
    %{
      helper: Keyword.get(opts, :helper) || Map.get(metadata, :imessage_helper) || HelperPort,
      server: Keyword.get(opts, :server) || Map.get(metadata, :imessage_server) || HelperPort
    }
  end

  defp routing_opts(metadata) do
    []
    |> put_present_kw(:helper, Map.get(metadata, :imessage_helper))
    |> put_present_kw(:server, Map.get(metadata, :imessage_server))
  end

  defp nested(row, outer, inner) do
    case Map.get(row, outer) do
      %{} = map -> Map.get(map, inner)
      _other -> nil
    end
  end

  defp present(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp put_present_kw(keyword, _key, nil), do: keyword
  defp put_present_kw(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp uuid4 do
    <<a::48, _version::4, b::12, _variant::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end

  defp bounded(term) when is_binary(term), do: String.slice(term, 0, @diagnostic_max)
  defp bounded(term), do: term |> inspect() |> String.slice(0, @diagnostic_max)
end
