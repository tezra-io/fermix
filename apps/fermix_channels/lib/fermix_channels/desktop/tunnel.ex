defmodule FermixChannels.Desktop.Tunnel do
  @moduledoc """
  One connection to a desktop engine's `companion.sock`, carried to its
  primary (M75 §6, B1).

  After a move, the device-role engine's companion endpoint hands each
  accepted connection to a tunnel instead of a `Companion.Connection`. The
  primary runs the ordinary companion connection for it; the tunnel is the
  wire between the two: each line the app writes goes to the primary as one
  `companion_line` of the tunnel's `channel` (`Desktop.Relay`), and each line
  the primary's connection writes comes back to the app as it was written.

  ## Who may use it

  Before it reads a line it places the process that connected, with the
  resolver every local socket uses (`FermixCore.SocketPeer`). The primary
  serves the channel with owner trust, so only the owner's app reaches it:
  a process this engine started (a command the primary's agent asked this
  desktop to run) or a detached one is refused with
  `error: unattended_client`, and one that cannot be placed with
  `error: unidentified_client`. Neither reaches the primary.

  ## The primary unreachable, or this desktop revoked

  A connection that arrives while the relay has no session, or whose channel
  the relay could not open, is answered with `error: primary_unreachable`,
  its `message` naming the primary, and closed; so is every open one when the
  session drops. The app keeps its outbox and reconnects. Once the primary no
  longer knows this computer (revoked), which no retry mends until the
  engine restarts, the reason is `desktop_revoked` instead, its `message` the
  relay's sentence, so the app stops keeping messages that can never be sent.

  ## Media, answered here

  A `media_fetch` asks for a file on this machine, so it is answered here:
  once the app's `client_hello` declared a version that has it, the relay
  fetches the blob with the phone wire's `media_fetch` and stages it, and
  `Companion.MediaGrants` grants the managed file as it does on any engine,
  answered `media_path` or `media_missing`. A `media_release` is answered by
  nothing, as on any engine. Every other line, the hello included, is the
  primary's.
  """

  use GenServer, restart: :temporary

  require Logger

  alias FermixChannels.Companion.MediaGrants
  alias FermixChannels.Desktop.Relay
  alias FermixChannels.Desktop.Relay.Media
  alias FermixCore.Companion.Protocol
  alias FermixCore.SocketPeer

  @profile "main"
  @handover_timeout_ms 5_000
  @media_events ~w(media_fetch media_release)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Every `error.reason` a tunnel sends itself; every other comes from the primary."
  @spec error_reasons() :: [String.t()]
  def error_reasons,
    do: ~w(primary_unreachable desktop_revoked unattended_client unidentified_client
           line_too_large max_clients_reached unsupported_profile request_failed)

  @impl true
  def init(opts) do
    state = %{
      socket: Keyword.fetch!(opts, :socket),
      relay: Keyword.get(opts, :relay, Relay),
      media_grants: Keyword.get(opts, :media_grants, MediaGrants),
      media_grants_module: Keyword.get(opts, :media_grants_module, MediaGrants),
      staging: Keyword.fetch!(opts, :staging),
      daemon_os_pid: Keyword.get(opts, :daemon_os_pid, String.to_integer(System.pid())),
      os: Keyword.get(opts, :os, :os.type()),
      channel: nil,
      relay_monitor: nil,
      buffer: "",
      version: nil
    }

    {:ok, state, @handover_timeout_ms}
  end

  @impl true
  def handle_info(:socket_handover, state) do
    case SocketPeer.classify(state.socket, state.daemon_os_pid, state.os) do
      {:ok, :independent} -> open(state)
      {:ok, placed} -> refuse("unattended_client", unattended(placed), state)
      {:error, :peer_closed} -> {:stop, :normal, state}
      {:error, reason} -> refuse("unidentified_client", unidentified(reason), state)
    end
  end

  # The endpoint died between starting this process and handing it the socket.
  def handle_info(:timeout, %{channel: nil} = state),
    do: {:stop, {:shutdown, :handover_timeout}, state}

  def handle_info({:tcp, socket, bytes}, %{socket: socket} = state) do
    case drain(%{state | buffer: state.buffer <> bytes}) do
      {:cont, state} -> rearm(state)
      {:stop, state} -> {:stop, :normal, close(state)}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, :normal, close(state)}

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: {:stop, :normal, close(state)}

  def handle_info({:relay_line, channel, line}, %{channel: channel} = state) do
    case :gen_tcp.send(state.socket, [line, "\n"]) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, close(state)}
    end
  end

  # The primary's connection ended; its last lines (an error, say) are
  # already written.
  def handle_info({:relay_closed, channel, _reason}, %{channel: channel} = state),
    do: {:stop, :normal, state}

  def handle_info({:relay_down, channel, sentence}, %{channel: channel} = state),
    do: refuse("primary_unreachable", sentence, state)

  def handle_info({:relay_revoked, channel, sentence}, %{channel: channel} = state),
    do: refuse("desktop_revoked", sentence, state)

  def handle_info({:DOWN, monitor, :process, _relay, _reason}, %{relay_monitor: monitor} = state),
    do: refuse("primary_unreachable", "Fermix lost its link to the server.", state)

  def handle_info({:relay_media, ref, result}, state), do: media_answer(ref, result, state)

  def handle_info(message, state) do
    Logger.debug("desktop tunnel ignored #{inspect(message)}")
    {:noreply, state}
  end

  # -- opening -----------------------------------------------------------------

  defp open(state) do
    case Relay.open_channel(state.relay) do
      {:ok, channel, relay} ->
        arm(%{state | channel: channel, relay_monitor: Process.monitor(relay)})

      {:error, {:unreachable, sentence}} ->
        refuse("primary_unreachable", sentence, state)

      {:error, {:revoked, sentence}} ->
        refuse("desktop_revoked", sentence, state)

      {:error, :busy} ->
        refuse("max_clients_reached", nil, state)
    end
  end

  defp arm(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:shutdown, {:socket_arm_failed, reason}}, close(state)}
    end
  end

  defp rearm(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, close(state)}
    end
  end

  defp unattended(placed) do
    Logger.warning(
      "desktop tunnel refused a #{placed} client: only the owner's app reaches the primary"
    )

    "Only the Fermix app chats with the server from this computer, and this " <>
      "process was started by Fermix or runs detached."
  end

  defp unidentified(reason) do
    Logger.warning("desktop tunnel refused a client it could not identify: #{inspect(reason)}")
    "The daemon could not identify the process on this connection."
  end

  # -- lines ---------------------------------------------------------------------

  defp drain(state) do
    case :binary.split(state.buffer, "\n") do
      [line, rest] -> state |> Map.put(:buffer, rest) |> line(line) |> continue()
      [_partial] -> partial(state)
    end
  end

  defp continue({:cont, state}), do: drain(state)
  defp continue({:stop, state}), do: {:stop, state}

  defp partial(state) do
    if byte_size(state.buffer) > Protocol.max_line_bytes(),
      do: {:stop, write_error("line_too_large", nil, state)},
      else: {:cont, state}
  end

  defp line(state, line) do
    cond do
      byte_size(line) > Protocol.max_line_bytes() ->
        {:stop, write_error("line_too_large", nil, state)}

      String.trim(line) == "" ->
        {:cont, state}

      true ->
        route(String.trim(line), state)
    end
  end

  # A media event is answered here once the hello declared a version that
  # has it; every other line, the hello and any refusal included, is the
  # primary's to answer.
  defp route(line, state) do
    case local(line, state) do
      {:ok, %{type: "media_fetch", payload: payload}} -> media_fetch(payload, state)
      {:ok, %{type: "media_release", payload: payload}} -> media_release(payload, state)
      :primary -> forward(line, state)
    end
  end

  defp local(line, %{version: version}) when is_integer(version) do
    with true <- String.contains?(line, "media_"),
         {:ok, %{type: type} = event} when type in @media_events <-
           Protocol.decode_client_event(line),
         true <- Protocol.client_event_version(type) <= version do
      {:ok, event}
    else
      _primary -> :primary
    end
  end

  defp local(_line, _state), do: :primary

  defp forward(line, state) do
    :ok = Relay.send_line(state.relay, state.channel, line)
    {:cont, hello_version(line, state)}
  end

  # The version the app's hello declared, read once.
  defp hello_version(line, %{version: nil} = state) do
    case Jason.decode(line) do
      {:ok, %{"type" => "client_hello", "protocol_version" => version}}
      when is_integer(version) ->
        %{state | version: version}

      _other ->
        state
    end
  end

  defp hello_version(_line, state), do: state

  # -- media ---------------------------------------------------------------------

  defp media_fetch(%{"profile_id" => @profile, "ref" => ref}, state) do
    case Relay.fetch_media(state.relay, ref) do
      :ok -> {:cont, state}
      {:error, {:unreachable, sentence}} -> write_reply(request_failed(sentence, ref), state)
      {:error, :busy} -> write_reply(request_failed(busy_sentence(), ref), state)
    end
  end

  defp media_fetch(_payload, state),
    do: write_reply({"error", %{"reason" => "unsupported_profile"}}, state)

  defp media_release(%{"profile_id" => @profile, "ref" => ref}, state) do
    :ok = state.media_grants_module.release(state.media_grants, ref, self())
    {:cont, state}
  end

  defp media_release(_payload, state),
    do: write_reply({"error", %{"reason" => "unsupported_profile"}}, state)

  defp busy_sentence, do: "Fermix is already fetching as much media as it may. Try again."

  # The relay staged the blob, or says why not: granted as any engine grants
  # it, and the staged copy goes once the grant took its own.
  defp media_answer(ref, {:ok, media}, state) do
    granted = state.media_grants_module.grant(state.media_grants, media, self())
    :ok = Media.discard(state.staging, ref)
    reply(granted_answer(granted, media), state)
  end

  defp media_answer(ref, {:error, :media_missing}, state),
    do: reply({"media_missing", %{"ref" => ref}}, state)

  defp media_answer(ref, {:error, {:unreachable, sentence}}, state),
    do: reply(request_failed(sentence, ref), state)

  defp media_answer(ref, {:error, reason}, state) do
    Logger.warning("desktop tunnel could not fetch media #{ref}: #{inspect(reason)}")
    reply(request_failed("Fermix could not fetch that file from the server.", ref), state)
  end

  defp granted_answer({:ok, path}, media) do
    {"media_path",
     %{
       "ref" => media.ref,
       "path" => path,
       "kind" => media.kind,
       "mime" => media.mime,
       "size_bytes" => media.size_bytes,
       "sha256" => media.ref
     }}
  end

  defp granted_answer({:error, :media_missing}, media),
    do: {"media_missing", %{"ref" => media.ref}}

  defp granted_answer({:error, reason}, media) do
    Logger.warning("desktop tunnel could not grant media #{media.ref}: #{inspect(reason)}")
    request_failed("Fermix could not make a file for that media.", media.ref)
  end

  defp request_failed(message, ref),
    do: {"error", %{"reason" => "request_failed", "message" => message, "ref" => ref}}

  defp reply({type, payload}, state) do
    case write(type, payload, state) do
      :ok -> {:noreply, state}
      {:error, _reason} -> {:stop, :normal, close(state)}
    end
  end

  defp write_reply({type, payload}, state) do
    case write(type, payload, state) do
      :ok -> {:cont, state}
      {:error, _reason} -> {:stop, state}
    end
  end

  # -- endings -------------------------------------------------------------------

  defp refuse(reason, message, state) do
    _ = write_error(reason, message, state)
    {:stop, :normal, close(state)}
  end

  defp write_error(reason, message, state) do
    payload =
      if message, do: %{"reason" => reason, "message" => message}, else: %{"reason" => reason}

    _ = write("error", payload, state)
    state
  end

  defp write(type, payload, state) do
    with {:ok, line} <- Protocol.encode_server_event(type, payload) do
      :gen_tcp.send(state.socket, line)
    end
  end

  # The channel ends with the connection; the relay tells the primary.
  defp close(%{channel: nil} = state), do: state

  defp close(state) do
    :ok = Relay.close_channel(state.relay, state.channel)
    %{state | channel: nil}
  end
end
