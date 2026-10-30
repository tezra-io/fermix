defmodule FermixChannels.Desktop.Invocations do
  @moduledoc """
  The executor family of a desktop session (M75 §11) and the primary's
  `FermixCore.DeviceActions`: how `device_action` reaches the owner's desktops.

  **As the family** (`Desktop.Family`, `executor` in `Desktop.Peer`'s map), in
  each connected desktop's peer: when the desktop's session starts it tells
  `Desktop.InvocationRegistry`, which asks the desktop about every invocation
  still in flight (`invoke_status`); every `invoke_blob`, `invoke_result` and
  `invoke_receipts` the desktop sends goes to that registry, which settles the
  waiting caller. The registry lives outside the peer, so an invocation
  outlives the session it was sent on.

  **As `FermixCore.DeviceActions`**, in the caller (`device_action`'s turn):

    * `desktops/0` lists the `desktop` rows of the running trust store
      (`Mobile.DeviceStore`) with whether each is connected now
      (`Desktop.Peer.connected/1`); with the phone channel off no desktop can
      connect, and the list is empty;
    * `invoke/4` names the invocation, puts the turn's correlation id in its
      arguments (`correlation_id`, which the desktop echoes in its result and
      logs), and waits on the registry. A `read_file`'s bytes go through the
      engine's one inbound attachment pipeline (`Gateway.Attachments`, M67),
      so the model gets the file as the `[attachments]` manifest and its
      content parts, exactly as a file sent in a chat, never as raw bytes.
  """

  @behaviour FermixChannels.Desktop.Family
  @behaviour FermixCore.DeviceActions

  require Logger

  alias FermixChannels.Desktop.InvocationRegistry
  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Gateway.Attachments
  alias FermixChannels.Gateway.MediaDownload
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Mobile.DeviceStore

  @registry InvocationRegistry
  @peers FermixChannels.Desktop.Peers
  @channel "desktop"

  # --- the family (in the desktop's peer) -----------------------------------

  @impl FermixChannels.Desktop.Family
  def init(%{device_id: device_id}) do
    :ok = InvocationRegistry.connected(@registry, device_id)
    {:ok, %{device_id: device_id}}
  end

  @impl FermixChannels.Desktop.Family
  def handle_event("invoke_blob", %{"invocation_id" => id}, payload, state),
    do: answer(InvocationRegistry.blob(@registry, state.device_id, id, payload), state)

  def handle_event("invoke_result", %{"invocation_id" => id, "status" => status}, payload, state),
    do: answer(InvocationRegistry.result(@registry, state.device_id, id, status, payload), state)

  def handle_event(
        "invoke_receipts",
        %{"status_id" => status_id, "receipts" => receipts},
        _payload,
        state
      ),
      do:
        answer(
          InvocationRegistry.receipts(@registry, state.device_id, status_id, receipts),
          state
        )

  @impl FermixChannels.Desktop.Family
  def handle_info(message, state) do
    Logger.warning("desktop #{state.device_id} executor family ignored #{inspect(message)}")
    {:ok, state}
  end

  @impl FermixChannels.Desktop.Family
  def terminate(_reason, _state), do: :ok

  defp answer(:ok, state), do: {:ok, state}
  defp answer({:error, reason}, state), do: {:error, reason, state}

  # --- FermixCore.DeviceActions (in the caller) ----------------------------

  @impl FermixCore.DeviceActions
  def desktops do
    case running_rows() do
      {:ok, rows} ->
        connected = connected_ids()

        for %{kind: :desktop} = row <- rows do
          %{
            device_id: row.device_id,
            name: row.name,
            executor: row.executor == true,
            connected: MapSet.member?(connected, row.device_id)
          }
        end

      :not_running ->
        []
    end
  end

  # The running store only: with the phone channel off (or this engine not the
  # primary) its subtree does not run, and no desktop could connect.
  defp running_rows do
    if GenServer.whereis(DeviceStore) do
      case DeviceStore.list(DeviceStore) do
        {:ok, rows} ->
          {:ok, rows}

        {:error, reason} ->
          Logger.error("desktop actions: the trust store could not be read: #{inspect(reason)}")
          :not_running
      end
    else
      :not_running
    end
  end

  defp connected_ids do
    if GenServer.whereis(@peers),
      do: @peers |> Peer.connected() |> MapSet.new(& &1.device_id),
      else: MapSet.new()
  end

  @impl FermixCore.DeviceActions
  def invoke(device_id, action, args, opts)
      when is_binary(device_id) and is_binary(action) and is_map(args) and is_list(opts) do
    invoke(device_id, action, args, opts, @registry)
  end

  @doc """
  `invoke/4` against the registry `server` (a test's own). Sends nothing when
  the registry is not running, which is no desktop connected.
  """
  @spec invoke(String.t(), String.t(), map(), keyword(), GenServer.server()) ::
          {:ok, FermixCore.DeviceActions.outcome()} | {:error, FermixCore.DeviceActions.error()}
  def invoke(device_id, action, args, opts, server) do
    deadline_s = Keyword.fetch!(opts, :deadline_s)
    correlation_id = Keyword.fetch!(opts, :correlation_id)
    id = invocation_id()
    payload = Jason.encode!(Map.put(args, "correlation_id", correlation_id))

    if GenServer.whereis(server) do
      server
      |> InvocationRegistry.invoke(device_id, id, action, payload, deadline_s)
      |> outcome(action, args)
    else
      {:error, :not_connected}
    end
  end

  defp invocation_id, do: "inv-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp outcome({:ok, %{kind: :result, status: :ok} = raw}, "read_file", args),
    do: attachment(raw, args)

  defp outcome({:ok, %{kind: :result} = raw}, _action, _args),
    do: {:ok, raw |> Map.delete(:blob) |> Map.put(:attachment, nil)}

  defp outcome({:ok, raw}, _action, _args), do: {:ok, raw}
  defp outcome({:error, {:invoke_rejected, reason}}, action, _args), do: rejected!(action, reason)
  defp outcome({:error, reason}, _action, _args), do: {:error, reason}

  # An invoke the wire refuses to encode is this engine's bug, never the
  # desktop's: it fails loud.
  defp rejected!(action, reason),
    do: raise(ArgumentError, "a #{action} invoke could not be sent: #{inspect(reason)}")

  # --- a read_file's bytes, through the attachment pipeline -----------------

  defp attachment(%{blob: nil} = raw, _args),
    do: {:error, {:attachment, {:no_bytes, raw.invocation_id}}}

  defp attachment(%{blob: bytes} = raw, %{"path" => path}) do
    declared = %{
      data: bytes,
      file_name: file_name(raw.result, path),
      size_bytes: byte_size(bytes)
    }

    message =
      Message.new!(%{
        id: raw.invocation_id,
        content: "",
        sender: @channel,
        channel: @channel,
        chat_id: @channel,
        reply_target: @channel,
        attachments: [declared]
      })

    case Attachments.ingest(__MODULE__, message, []) do
      {:ok, %Message{inbound_attachments: [rendered]}} ->
        {:ok,
         raw
         |> Map.delete(:blob)
         |> Map.put(:attachment, rendered)}

      {:error, reason} ->
        {:error, {:attachment, reason}}
    end
  end

  defp file_name(%{"name" => name}, _path) when is_binary(name) and name != "", do: name
  defp file_name(_result, path), do: Path.basename(path)

  @doc """
  The pipeline's fetch for a desktop's file: its bytes, which the primary
  already holds, written to a private temp file like any channel's download.
  """
  @spec download_attachment(Message.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def download_attachment(_message, %{data: data} = declared) when is_binary(data),
    do: MediaDownload.write_temp_bytes(data, @channel, extension(declared))

  def download_attachment(_message, _declared), do: {:error, :missing_attachment_reference}

  # The file's own extension, so a transcription backend reads the format from
  # the temp name; only letters and digits survive.
  defp extension(declared) do
    case declared |> Map.get(:file_name, "") |> Path.extname() do
      "." <> ext -> "." <> String.replace(ext, ~r/[^A-Za-z0-9]/, "")
      _none -> ".bin"
    end
  end
end
