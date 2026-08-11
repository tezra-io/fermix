defmodule FermixChannels.Channels.Signal do
  @moduledoc """
  Signal direct-message channel adapter.

  Uses a supervised `signal-cli` receive loop for inbound direct messages and a
  subprocess send path for outbound replies. Initial M3 scope is direct text
  messaging first, with attachment metadata preserved when present.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Channels.Signal.Plain
  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.MediaDownload
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Outbound.Splitter
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Telemetry

  @default_cli_path "signal-cli"
  @max_media_bytes 100 * 1_024 * 1_024
  # Signal imposes no outbound text cap. This ceiling is a Fermix readability
  # choice (CHANNEL_LONGFORM_PRESENTATION §3.1) — a long reply arrives as a few
  # readable messages instead of one unbounded wall — not a platform limit. With
  # no platform counting anything, the unit is ours to pick, and graphemes (the
  # splitter's default) are the reader-visible characters a readability ceiling
  # is actually about. The only certain unit of the five channels.
  @max_message_length 4_000

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @doc false
  @spec parse_receive_entry(map(), keyword()) ::
          {:ok, [FermixChannels.Gateway.Channel.message()]} | {:error, term()}
  def parse_receive_entry(entry, opts \\ []) when is_map(entry) do
    {result, duration_us} =
      Telemetry.timed_us(fn -> do_parse_receive_entry(entry, opts) end)

    ChannelTelemetry.emit_parse(:signal, result, duration_us)
    maybe_emit_inbound_message(result, duration_us)
    result
  end

  defp do_parse_receive_entry(entry, opts) do
    messages =
      if ingress_enabled?() do
        entry
        |> build_receive_message(opts)
        |> List.wrap()
      else
        []
      end

    {:ok, messages}
  end

  @doc false
  @spec receive_messages(keyword()) :: {:ok, [map()]} | {:error, term()}
  def receive_messages(opts \\ []) do
    with {:ok, receive_opts} <- receive_opts(opts) do
      receive_client(opts).receive_messages(receive_opts)
    end
  end

  @impl true
  @spec send_message(String.t(), String.t()) :: :ok | {:error, term()}
  @spec send_message(String.t(), String.t(), FermixChannels.Gateway.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(recipient, text, opts \\ []) when is_binary(recipient) and is_binary(text) do
    # M30 §11.3: an unconfigured account means there is no Signal client to send
    # through, which is the `:adapter_unavailable` kind of the closed delivery
    # vocabulary — not a bare atom the delivery normalizer would have to guess at.
    case account() do
      {:ok, account} -> send_text(account, recipient, text, opts)
      {:error, :not_configured} -> {:error, {:permanent, :adapter_unavailable}}
    end
  end

  # CHANNEL_LONGFORM_PRESENTATION §3.1: the ladder walks the model's Markdown —
  # that is where headings and section boundaries are still legible — while
  # every candidate chunk is *measured* through the plain-text renderer, so the
  # readability ceiling counts what the reader sees rather than the markup the
  # model wrote. Each emitted chunk is then rendered for the wire.
  defp send_text(account, recipient, text, opts) do
    text
    |> Splitter.split(limit: @max_message_length, measure: &Plain.rendered_length/1)
    |> Enum.map(&Plain.render/1)
    |> send_chunks(account, recipient, opts)
  end

  # Strictly sequential: the first failure aborts the remaining chunks and is
  # the returned reason.
  defp send_chunks(chunks, account, recipient, opts) do
    client = send_client(opts)
    client_opts = client_opts(opts)

    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      halt_on_error(send_chunk(client, client_opts, account, recipient, chunk))
    end)
  end

  # One delivered message is one outbound row, emitted here rather than once for
  # the whole reply (design §8): a reply that half-lands then reports truthfully
  # what WAS delivered instead of reporting nothing.
  defp send_chunk(client, client_opts, account, recipient, chunk) do
    {result, duration_us} =
      Telemetry.timed_us(fn -> client.send_message(account, recipient, chunk, client_opts) end)

    emit_delivered(result, duration_us)
  end

  defp emit_delivered(:ok, duration_us), do: emit_outbound_telemetry(duration_us)
  defp emit_delivered({:error, _reason} = error, _duration_us), do: error

  defp halt_on_error(:ok), do: {:cont, :ok}
  defp halt_on_error({:error, _reason} = error), do: {:halt, error}

  @impl true
  @spec send_media(String.t(), FermixChannels.Gateway.Channel.media_part()) ::
          :ok | {:error, term()}
  @spec send_media(
          String.t(),
          FermixChannels.Gateway.Channel.media_part(),
          FermixChannels.Gateway.Channel.send_opts()
        ) ::
          :ok | {:error, term()}
  def send_media(recipient, media_part, opts \\ [])
      when is_binary(recipient) and is_map(media_part) do
    with {:ok, claim} <- Idempotency.claim_outbound_media(:signal, recipient, media_part) do
      send_claimed_media(claim, recipient, media_part, opts)
    end
  end

  @impl true
  @spec build_text_reply(FermixChannels.Gateway.Channel.message()) :: (String.t() ->
                                                                         :ok | {:error, term()})
  def build_text_reply(%Message{reply_target: reply_target, metadata: metadata}) do
    reply_opts =
      []
      |> put_if_present(:client, Map.get(metadata, :signal_client))
      |> put_if_present(:client_opts, Map.get(metadata, :signal_client_opts))

    fn text -> send_message(reply_target, text, reply_opts) end
  end

  @impl true
  @spec build_media_reply(FermixChannels.Gateway.Channel.message()) ::
          (FermixChannels.Gateway.Channel.media_part() -> :ok | {:error, term()})
  def build_media_reply(%Message{reply_target: reply_target, metadata: metadata}) do
    reply_opts =
      []
      |> put_if_present(:client, Map.get(metadata, :signal_client))
      |> put_if_present(:client_opts, Map.get(metadata, :signal_client_opts))

    fn media_part -> send_media(reply_target, media_part, reply_opts) end
  end

  # -- Reactions (docs/design/EMOJI_REACTION_ACKS.md §9) --

  @impl true
  @spec reaction_capability() :: :any_emoji
  def reaction_capability, do: :any_emoji

  @impl true
  @spec react(FermixChannels.Gateway.Channel.message(), String.t()) :: :ok | {:error, term()}
  def react(message, emoji, opts \\ [])

  def react(%Message{id: timestamp, reply_target: recipient, metadata: metadata}, emoji, opts)
      when is_binary(emoji) do
    # A Signal reaction targets a message by (author, timestamp). For a 1:1 chat
    # both the author and the recipient are the inbound sender; `Message.id` is
    # the message timestamp. `metadata.sender_id` carries the author (§9).
    author = Map.get(metadata, :sender_id) || recipient

    react_opts =
      opts
      |> put_if_present(:client, Map.get(metadata, :signal_client))
      |> put_if_present(:client_opts, Map.get(metadata, :signal_client_opts))

    with {:ok, account} <- account(),
         {:ok, :ok, duration_us} <-
           timed_signal_reaction(account, recipient, author, timestamp, emoji, react_opts) do
      emit_outbound_telemetry(duration_us)
    end
  end

  @impl true
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

  @impl true
  @spec health_check(keyword()) :: FermixChannels.Gateway.Channel.health_result()
  def health_check(opts \\ []) do
    start = System.monotonic_time(:millisecond)

    with {:ok, account} <- account(),
         {:ok, _path} <- resolved_cli_path(opts) do
      {:ok, %{detail: "Signal account #{account} configured", latency_ms: elapsed_ms(start)}}
    else
      {:error, :not_configured} ->
        {:error, {:misconfigured, "signal account is not configured"}}

      {:error, {:missing_executable, path}} ->
        {:error, {:misconfigured, "signal-cli executable not found at #{path}"}}
    end
  end

  defp build_receive_message(entry, opts) do
    envelope = Map.get(entry, "envelope", %{})
    data_message = Map.get(envelope, "dataMessage", %{})
    sender_id = Map.get(envelope, "sourceNumber")
    timestamp = data_message["timestamp"] || envelope["timestamp"]

    cond do
      sender_id in [nil, ""] ->
        nil

      not direct_message?(data_message) ->
        nil

      true ->
        Message.new!(%{
          id: to_string(timestamp),
          content: Map.get(data_message, "message", ""),
          sender: Map.get(envelope, "sourceName") || sender_id,
          channel: "signal",
          chat_id: sender_id,
          reply_target: sender_id,
          metadata: %{
            sender_id: sender_id,
            user_id: sender_id,
            chat_type: "private",
            timestamp: timestamp,
            signal_client: send_client(opts),
            signal_client_opts: client_opts(opts)
          },
          attachments: parse_attachments(Map.get(data_message, "attachments", []))
        })
    end
  end

  defp direct_message?(data_message) do
    is_map(data_message) and not Map.has_key?(data_message, "groupInfo") and
      not Map.has_key?(data_message, "groupV2")
  end

  defp parse_attachments(attachments) when is_list(attachments) do
    Enum.map(attachments, fn attachment ->
      mime_type = Map.get(attachment, "contentType")

      %{
        kind: attachment_kind(mime_type),
        url: Map.get(attachment, "storedFilename"),
        mime_type: mime_type,
        file_id: Map.get(attachment, "id"),
        size_bytes: Map.get(attachment, "size")
      }
    end)
  end

  defp parse_attachments(_attachments), do: []

  defp send_claimed_media(:duplicate, _recipient, _media_part, _opts), do: :ok

  defp send_claimed_media({:fresh, claim}, recipient, media_part, opts) do
    result =
      with {:ok, account} <- account(),
           :ok <- validate_media(media_part),
           {:ok, :ok, duration_us} <-
             timed_signal_attachment_send(account, recipient, media_part, opts) do
        emit_outbound_telemetry(duration_us)
      end

    maybe_release_claim(result, claim)
  end

  defp validate_media(%{path: path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @max_media_bytes ->
        :ok

      {:ok, %{size: size}} ->
        {:error, {:byte_cap_exceeded, size, @max_media_bytes}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_media(_media_part), do: {:error, :invalid_media_part}

  defp timed_signal_attachment_send(account, recipient, media_part, opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        send_client(opts).send_attachment(
          account,
          recipient,
          media_caption(media_part),
          media_part.path,
          client_opts(opts)
        )
      end)

    case result do
      :ok -> {:ok, :ok, duration_us}
      {:error, reason} -> {:error, reason}
    end
  end

  defp timed_signal_reaction(account, recipient, author, timestamp, emoji, opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        send_client(opts).send_reaction(
          account,
          recipient,
          author,
          timestamp,
          emoji,
          client_opts(opts)
        )
      end)

    case result do
      :ok -> {:ok, :ok, duration_us}
      {:error, reason} -> {:error, reason}
    end
  end

  defp media_caption(%{caption: caption}) when is_binary(caption), do: caption
  defp media_caption(_media_part), do: ""

  defp maybe_release_claim(:ok, _claim), do: :ok

  defp maybe_release_claim({:error, _reason} = error, claim) do
    :ok = Idempotency.release_outbound_media_claim(claim)
    error
  end

  @impl true
  @spec download_attachment(FermixChannels.Gateway.Channel.message(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def download_attachment(_message, attachment) when is_map(attachment) do
    with :ok <- MediaDownload.preflight_cap(attachment, @max_media_bytes),
         {:ok, source} <- local_source(attachment),
         {:ok, body} <- read_local_attachment(source),
         {:ok, body} <- MediaDownload.enforce_cap(body, @max_media_bytes),
         {:ok, path} <- MediaDownload.write_temp(body, "signal", attachment) do
      {:ok, path}
    end
  end

  defp local_source(attachment) do
    case MediaDownload.value(attachment, :url) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, :missing_attachment_reference}
    end
  end

  # signal-cli stores inbound media as a local file on its own host; copy the
  # bytes into our own temp so cleanup never deletes signal-cli's original. Fail
  # loud if the path is unreadable (e.g. signal-cli runs on a different host).
  defp read_local_attachment(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:attachment_unreadable, reason}}
    end
  end

  defp attachment_kind("audio/" <> _rest), do: :audio
  defp attachment_kind("image/" <> _rest), do: :image
  defp attachment_kind(_mime_type), do: :file

  defp ingress_enabled? do
    case FermixCore.Config.channel(:signal) do
      {:ok, config} -> Keyword.get(config, :enabled, false) == true
      _ -> false
    end
  end

  defp receive_client(opts) do
    Keyword.get(opts, :client) || config_value(:client) || FermixChannels.Channels.Signal.CLI
  end

  defp send_client(opts) do
    Keyword.get(opts, :client) || config_value(:client) || FermixChannels.Channels.Signal.CLI
  end

  defp client_opts(opts) do
    case Keyword.fetch(opts, :client_opts) do
      {:ok, client_opts} ->
        client_opts

      :error ->
        case FermixCore.Config.channel(:signal) do
          {:ok, config} -> Keyword.get(config, :client_opts, [])
          _ -> []
        end
    end
  end

  defp receive_opts(opts) do
    with {:ok, account} <- account() do
      {:ok,
       [
         account: account,
         cli_path: cli_path()
       ] ++ client_opts(opts)}
    end
  end

  defp account do
    with {:ok, config} <- FermixCore.Config.channel(:signal),
         value when is_binary(value) and value != "" <- Keyword.get(config, :account) do
      {:ok, value}
    else
      _ -> {:error, :not_configured}
    end
  end

  defp cli_path do
    case FermixCore.Config.channel(:signal) do
      {:ok, config} ->
        case Keyword.get(config, :cli_path) do
          value when is_binary(value) and value != "" -> value
          _ -> @default_cli_path
        end

      _ ->
        @default_cli_path
    end
  end

  defp resolved_cli_path(opts) do
    resolver = Keyword.get(opts, :executable_resolver, &System.find_executable/1)
    path = Keyword.get(opts, :cli_path) || cli_path()

    cond do
      Path.type(path) == :absolute and File.exists?(path) ->
        {:ok, path}

      Path.type(path) == :absolute ->
        {:error, {:missing_executable, path}}

      resolved = resolver.(path) ->
        {:ok, resolved}

      true ->
        {:error, {:missing_executable, path}}
    end
  end

  defp config_value(key) do
    case FermixCore.Config.channel(:signal) do
      {:ok, config} -> Keyword.get(config, key)
      _ -> nil
    end
  end

  defp emit_outbound_telemetry(duration_us) do
    ChannelTelemetry.emit_message(:signal, :outbound, 1, duration_us)
    :ok
  end

  defp maybe_emit_inbound_message({:ok, messages}, duration_us) when messages != [] do
    ChannelTelemetry.emit_message(:signal, :inbound, length(messages), duration_us)
  end

  defp maybe_emit_inbound_message(_result, _duration_us), do: :ok

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)
  defp elapsed_ms(start), do: System.monotonic_time(:millisecond) - start
end

defmodule FermixChannels.Channels.Signal.CLI do
  @moduledoc false

  require Logger

  alias FermixCore.CommandRunner

  @receive_timeout_ms 60_000
  @send_timeout_ms 30_000

  # Ceiling for the bounded local diagnostic of CLI output (M30 §11.3).
  @diagnostic_max 500

  def receive_messages(opts) do
    cli_path = resolve_cli(opts)
    account = Keyword.fetch!(opts, :account)
    timeout_ms = Keyword.get(opts, :timeout_ms, @receive_timeout_ms)

    case CommandRunner.run(cli_path, ["-a", account, "receive", "--output", "json"],
           timeout_ms: timeout_ms
         ) do
      {:ok, %{exit: 0, stdout: output}} ->
        decode_receive_output(output)

      {:ok, %{exit: status, stdout: output}} ->
        {:error, "signal-cli receive failed: #{status}: #{String.trim(output)}"}

      {:error, {:timeout, ms}} ->
        {:error, "signal-cli receive timed out after #{ms}ms"}

      {:error, {:executable_not_found, path}} ->
        {:error, "signal-cli executable not found at #{path}"}
    end
  end

  def send_message(account, recipient, text, opts) do
    cli_path = resolve_cli(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @send_timeout_ms)

    cli_path
    |> CommandRunner.run(["-a", account, "send", "-m", text, recipient], timeout_ms: timeout_ms)
    |> classify_send_result()
  end

  @doc """
  Classifies one `signal-cli send` run into the closed delivery-error vocabulary
  (M30 §11.3): a non-zero exit is a permanent remote rejection, a watchdog
  expiry or a command-host/port failure is a transport failure, and a missing
  executable is an unavailable adapter. `CommandRunner.reason/0` is open, so the
  last clause classifies anything else as a terminal contract violation instead
  of raising — this function is where that openness is closed.

  Free-form CLI output is a local diagnostic only — it is logged bounded and
  never reaches the returned reason, which is why this classifier takes the raw
  runner result and is exercised directly.
  """
  @spec classify_send_result(term()) :: :ok | {:error, term()}
  def classify_send_result({:ok, %{exit: 0}}), do: :ok

  def classify_send_result({:ok, %{exit: status, stdout: output}}) when is_integer(status) do
    Logger.warning(
      "signal-cli send failed: exit #{status}: #{String.slice(String.trim(output), 0, @diagnostic_max)}"
    )

    {:error, {:permanent, :remote_rejected}}
  end

  def classify_send_result({:error, {:timeout, ms}}) do
    Logger.warning("signal-cli send timed out after #{ms}ms")
    {:error, {:transport, :timeout}}
  end

  def classify_send_result({:error, {:executable_not_found, path}}) do
    Logger.warning("signal-cli executable not found at #{path}")
    {:error, {:permanent, :adapter_unavailable}}
  end

  # The supervised runner path (the daemon's normal route) also reports its own
  # failures: a `CommandHost` that refused to start or died, and a port that
  # never opened. Those are the local transport for a CLI channel, and they are
  # worth another claim cycle. Unhandled they would raise here and surface three
  # layers up as a terminal worker crash on attempt one.
  def classify_send_result({:error, {kind, reason}})
      when kind in [:command_host_crashed, :port_failed] do
    Logger.warning("signal-cli send transport failed (#{kind}): #{inspect(reason)}")
    {:error, {:transport, :timeout}}
  end

  # `CommandRunner.reason/0` is open by type. This function is the boundary that
  # closes it, so an unrecognized shape is classified here — loudly and
  # terminally — rather than crashing the caller.
  def classify_send_result(result) do
    Logger.error(
      "signal-cli send returned an unrecognized runner result: " <>
        String.slice(inspect(result), 0, @diagnostic_max)
    )

    {:error, {:unexpected_delivery_result, :invalid_contract}}
  end

  def send_attachment(account, recipient, caption, path, opts) do
    cli_path = resolve_cli(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @send_timeout_ms)
    args = ["-a", account, "send", "-m", caption, "--attachment", path, recipient]

    case CommandRunner.run(cli_path, args, timeout_ms: timeout_ms) do
      {:ok, %{exit: 0}} ->
        :ok

      {:ok, %{exit: status, stdout: output}} ->
        {:error, "signal-cli attachment send failed: #{status}: #{String.trim(output)}"}

      {:error, {:timeout, ms}} ->
        {:error, "signal-cli attachment send timed out after #{ms}ms"}

      {:error, {:executable_not_found, path}} ->
        {:error, "signal-cli executable not found at #{path}"}
    end
  end

  # Long flags only: within the `sendReaction` subcommand, `-a` would be read as
  # --target-author, not the account (which is the global `-a` before the
  # subcommand), so target-author/timestamp use their unambiguous long forms.
  def send_reaction(account, recipient, author, timestamp, emoji, opts) do
    cli_path = resolve_cli(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @send_timeout_ms)

    args = [
      "-a",
      account,
      "sendReaction",
      "-e",
      emoji,
      "--target-author",
      author,
      "--target-timestamp",
      to_string(timestamp),
      recipient
    ]

    case CommandRunner.run(cli_path, args, timeout_ms: timeout_ms) do
      {:ok, %{exit: 0}} ->
        :ok

      {:ok, %{exit: status, stdout: output}} ->
        {:error, "signal-cli sendReaction failed: #{status}: #{String.trim(output)}"}

      {:error, {:timeout, ms}} ->
        {:error, "signal-cli sendReaction timed out after #{ms}ms"}

      {:error, {:executable_not_found, path}} ->
        {:error, "signal-cli executable not found at #{path}"}
    end
  end

  defp resolve_cli(opts) do
    case Keyword.get(opts, :cli_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        System.find_executable("signal-cli") || "signal-cli"
    end
  end

  defp decode_receive_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case Jason.decode(line) do
        {:ok, payload} -> {:cont, {:ok, [payload | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      {:error, reason} -> {:error, reason}
    end
  end
end
