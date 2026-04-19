defmodule FermixChannels.Signal do
  @moduledoc """
  Signal direct-message channel adapter.

  Uses a supervised `signal-cli` receive loop for inbound direct messages and a
  subprocess send path for outbound replies. Initial M3 scope is direct text
  messaging first, with attachment metadata preserved when present.
  """

  @behaviour FermixChannels.Channel

  alias FermixChannels.Message

  @default_cli_path "signal-cli"

  @impl true
  def parse_webhook(_params), do: {:error, :unsupported_transport}

  @doc false
  @spec parse_receive_entry(map(), keyword()) ::
          {:ok, [FermixChannels.Channel.message()]} | {:error, term()}
  def parse_receive_entry(entry, opts \\ []) when is_map(entry) do
    messages =
      if ingress_enabled?() do
        entry
        |> build_receive_message(opts)
        |> List.wrap()
      else
        []
      end

    if messages != [] do
      :telemetry.execute(
        [:fermix, :channel, :message],
        %{count: length(messages)},
        %{channel: :signal, direction: :inbound}
      )
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
  @spec send_message(String.t(), String.t(), FermixChannels.Channel.send_opts()) ::
          :ok | {:error, term()}
  def send_message(recipient, text, opts \\ []) when is_binary(recipient) and is_binary(text) do
    with {:ok, account} <- account(),
         :ok <- send_client(opts).send_message(account, recipient, text, client_opts(opts)) do
      emit_outbound_telemetry()
    end
  end

  @impl true
  @spec build_reply(FermixChannels.Channel.message()) :: FermixChannels.Channel.reply_fn()
  def build_reply(%Message{reply_target: reply_target, metadata: metadata}) do
    reply_opts =
      []
      |> put_if_present(:client, Map.get(metadata, :signal_client))
      |> put_if_present(:client_opts, Map.get(metadata, :signal_client_opts))

    fn text -> send_message(reply_target, text, reply_opts) end
  end

  @impl true
  def verify_webhook(_conn), do: {:error, :unsupported_transport}

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

      not authorized_sender?(sender_id) ->
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

  defp attachment_kind("audio/" <> _rest), do: :audio
  defp attachment_kind("image/" <> _rest), do: :image
  defp attachment_kind(_mime_type), do: :file

  defp authorized_sender?(sender_id) do
    allowed = allowed_sender_ids()
    allowed == [] or sender_id in allowed
  end

  defp allowed_sender_ids do
    with {:ok, config} <- FermixCore.Config.channel(:signal) do
      config
      |> Keyword.get(:allowed_sender_ids, [])
      |> Enum.map(&to_string/1)
    else
      _ -> []
    end
  end

  defp ingress_enabled? do
    case FermixCore.Config.channel(:signal) do
      {:ok, config} -> Keyword.get(config, :enabled, false) == true
      _ -> false
    end
  end

  defp receive_client(opts) do
    Keyword.get(opts, :client) || config_value(:client) || FermixChannels.Signal.CLI
  end

  defp send_client(opts) do
    Keyword.get(opts, :client) || config_value(:client) || FermixChannels.Signal.CLI
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

  defp config_value(key) do
    case FermixCore.Config.channel(:signal) do
      {:ok, config} -> Keyword.get(config, key)
      _ -> nil
    end
  end

  defp emit_outbound_telemetry do
    :telemetry.execute(
      [:fermix, :channel, :message],
      %{count: 1},
      %{channel: :signal, direction: :outbound}
    )

    :ok
  end

  defp put_if_present(keyword, _key, nil), do: keyword
  defp put_if_present(keyword, key, value), do: Keyword.put(keyword, key, value)
end

defmodule FermixChannels.Signal.CLI do
  @moduledoc false

  def receive_messages(opts) do
    cli_path = Keyword.get(opts, :cli_path, "signal-cli")
    account = Keyword.fetch!(opts, :account)

    case System.cmd(cli_path, ["-a", account, "receive", "--output", "json"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        decode_receive_output(output)

      {output, status} ->
        {:error, "signal-cli receive failed: #{status}: #{String.trim(output)}"}
    end
  end

  def send_message(account, recipient, text, opts) do
    cli_path = Keyword.get(opts, :cli_path, "signal-cli")

    case System.cmd(cli_path, ["-a", account, "send", "-m", text, recipient],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "signal-cli send failed: #{status}: #{String.trim(output)}"}
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
