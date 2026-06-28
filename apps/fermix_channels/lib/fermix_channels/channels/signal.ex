defmodule FermixChannels.Channels.Signal do
  @moduledoc """
  Signal direct-message channel adapter.

  Uses a supervised `signal-cli` receive loop for inbound direct messages and a
  subprocess send path for outbound replies. Initial M3 scope is direct text
  messaging first, with attachment metadata preserved when present.
  """

  @behaviour FermixChannels.Gateway.Channel

  require Logger

  alias FermixChannels.Gateway.Idempotency
  alias FermixChannels.Gateway.MediaDownload
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixCore.Telemetry

  @default_cli_path "signal-cli"
  @max_media_bytes 100 * 1_024 * 1_024

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
    with {:ok, account} <- account(),
         {:ok, :ok, duration_us} <- timed_signal_send(account, recipient, text, opts) do
      emit_outbound_telemetry(duration_us)
    end
  end

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

  defp timed_signal_send(account, recipient, text, opts) do
    {result, duration_us} =
      Telemetry.timed_us(fn ->
        send_client(opts).send_message(account, recipient, text, client_opts(opts))
      end)

    case result do
      :ok -> {:ok, :ok, duration_us}
      {:error, reason} -> {:error, reason}
    end
  end

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

  alias FermixCore.CommandRunner

  @receive_timeout_ms 60_000
  @send_timeout_ms 30_000

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

    case CommandRunner.run(cli_path, ["-a", account, "send", "-m", text, recipient],
           timeout_ms: timeout_ms
         ) do
      {:ok, %{exit: 0}} ->
        :ok

      {:ok, %{exit: status, stdout: output}} ->
        {:error, "signal-cli send failed: #{status}: #{String.trim(output)}"}

      {:error, {:timeout, ms}} ->
        {:error, "signal-cli send timed out after #{ms}ms"}

      {:error, {:executable_not_found, path}} ->
        {:error, "signal-cli executable not found at #{path}"}
    end
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
