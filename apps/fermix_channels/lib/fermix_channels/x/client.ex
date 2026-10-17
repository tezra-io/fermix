defmodule FermixChannels.X.Client do
  @moduledoc """
  The X channel's connection to Fermix Connect (`priv/connect/PROTOCOL.md` §3):
  it dials out, authenticates, and carries frames between the socket and
  `X.Pump`. Nothing listens on this machine.

  It dials `<origin>/v1/connect` over TLS with the instance id and key id in
  the upgrade headers and the `fermix-connect.v1` subprotocol; no secret
  travels in the upgrade. The socket refuses to dial through the outbound
  proxy, which it cannot tunnel (`Net.Egress.ensure_direct/2`, asked by
  `X.Client.Socket` before it dials), and verifies the peer against the OS
  trust store, those TLS options set last so nothing weakens them. Connect's `challenge` is answered with `hello`, signed by the
  instance key over `fermix-connect-session|<origin>|<instance_id>|<nonce>|1`;
  its `ready` names the session's caps, and from then on every frame goes to
  the pump and the pump's frames go out.

  A lost connection is redialed after an exponential backoff with jitter, from
  one second up to a one-minute ceiling, where it stays for as long as the channel runs: the
  channel is on, so it keeps trying, and its status says it is down. A close
  `4401` means the instance was revoked or unpaired and `4409` that another
  socket took this instance over: both are refused for good, reported to the
  pump, and never redialed. The session ends at Connect's `session_ttl_s`; it
  is closed shortly before, with jitter, and dialed again at once.

  The socket itself is `X.Client.Socket`, one process per connection, linked
  here; `start_link/2` and `start_options/2` are this module's whole dialing
  surface, so moving to another WebSocket client changes only that pair.
  """

  use GenServer

  require Logger

  alias FermixChannels.Telemetry, as: ChannelTelemetry
  alias FermixChannels.X.Client.Socket
  alias FermixChannels.X.Pairing
  alias FermixChannels.X.Pump
  alias FermixCore.Net.Egress
  alias FermixCore.Net.Tls

  @protocol_version 1
  @subprotocol "fermix-connect.v1"
  @connect_path "/v1/connect"
  @max_result_bytes 16_384
  @backoff_base_ms 1_000
  @backoff_ceiling_ms 60_000
  # The session is closed this share of its TTL early at most, so a reconnect
  # never waits for Connect to cut it.
  @ttl_jitter_share 10
  @reconnect_after_ttl_ms 1_000
  # Outlasts `WebSockex.send_frame/3`'s own five seconds.
  @send_timeout_ms 10_000
  @nonce ~r/\A[A-Za-z0-9_-]{43}\z/

  @type receipt :: :accepted | {:rejected, atom()}

  @doc """
  Starts the connection for `record`. `opts`: `:pump` (default `X.Pump`),
  `:pairing` (the `X.Pairing` options that find the instance key),
  `:socket_module` and `:socket_options` (tests), `:egress`, `:jitter`
  (`fn max -> 0..max end`), `:connect?` (default `true`) and `:name`.
  """
  @spec start_link(Pairing.t(), keyword()) :: GenServer.on_start()
  def start_link(%Pairing{} = record, opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, {record, opts}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec child_spec({Pairing.t(), keyword()}) :: Supervisor.child_spec()
  def child_spec({%Pairing{} = record, opts}) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [record, opts]}}
  end

  @doc """
  `opts` with the TLS options for `url`'s host set last, or
  `{:error, :ws_url_without_host}`.
  """
  @spec start_options(String.t(), keyword()) :: {:ok, keyword()} | {:error, :ws_url_without_host}
  def start_options(url, opts) when is_binary(url) and is_list(opts) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        {:ok, Keyword.put(opts, :ssl_options, Tls.client_options(host))}

      %URI{} ->
        {:error, :ws_url_without_host}
    end
  end

  @doc "The WebSocket URL for a pairing's origin."
  @spec url(Pairing.t()) :: String.t()
  def url(%Pairing{origin: "https://" <> host}), do: "wss://" <> host <> @connect_path

  @doc "What the instance key signs to answer a `challenge` (§3.1)."
  @spec session_message(Pairing.t(), String.t()) :: String.t()
  def session_message(%Pairing{} = record, nonce) when is_binary(nonce) do
    "fermix-connect-session|#{record.origin}|#{record.instance_id}|#{nonce}|#{@protocol_version}"
  end

  @spec send_receipt(GenServer.server(), String.t(), receipt()) :: :ok | {:error, term()}
  def send_receipt(server, assignment_id, :accepted) when is_binary(assignment_id),
    do:
      send_frame(server, %{
        "t" => "receipt",
        "assignment_id" => assignment_id,
        "outcome" => "accepted"
      })

  def send_receipt(server, assignment_id, {:rejected, reason})
      when is_binary(assignment_id) and is_atom(reason) do
    send_frame(server, %{
      "t" => "receipt",
      "assignment_id" => assignment_id,
      "outcome" => "rejected",
      "reason" => Atom.to_string(reason)
    })
  end

  @spec send_start(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_start(server, assignment_id) when is_binary(assignment_id),
    do: send_frame(server, %{"t" => "start", "assignment_id" => assignment_id})

  @doc "Sends a result frame exactly as the assignment's row holds it."
  @spec send_result(GenServer.server(), map()) :: :ok | {:error, term()}
  def send_result(server, %{"t" => "result"} = frame), do: send_frame(server, frame)

  @spec send_cancel_ack(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_cancel_ack(server, assignment_id) when is_binary(assignment_id),
    do: send_frame(server, %{"t" => "cancel_ack", "assignment_id" => assignment_id})

  defp send_frame(server, frame) do
    GenServer.call(server, {:send, Jason.encode!(frame)}, @send_timeout_ms)
  catch
    :exit, reason -> {:error, {:client_unavailable, reason}}
  end

  # --- GenServer -------------------------------------------------------------

  @impl true
  def init({record, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      record: record,
      pump: Keyword.get(opts, :pump, Pump),
      pairing: Keyword.get(opts, :pairing, []),
      socket_module: Keyword.get(opts, :socket_module, Socket),
      socket_options: Keyword.get(opts, :socket_options, []),
      egress: Keyword.get_lazy(opts, :egress, &Egress.active/0),
      jitter: Keyword.get(opts, :jitter, &default_jitter/1),
      socket: nil,
      phase: :idle,
      close_reason: nil,
      failures: 0,
      degraded?: false,
      ttl_timer: nil
    }

    if Keyword.get(opts, :connect?, true), do: send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call({:send, json}, _from, %{phase: :ready, socket: socket} = state) do
    {:reply, state.socket_module.send_json(socket, json), state}
  end

  def handle_call({:send, _json}, _from, state), do: {:reply, {:error, :not_connected}, state}

  @impl true
  def handle_info(:connect, %{socket: nil, phase: phase} = state)
      when phase in [:idle, :waiting],
      do: {:noreply, dial(state)}

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info(:session_ttl, %{socket: socket} = state) when is_pid(socket) do
    state.socket_module.close(socket)
    {:noreply, %{state | close_reason: :session_ttl, ttl_timer: nil}}
  end

  def handle_info(:session_ttl, state), do: {:noreply, %{state | ttl_timer: nil}}

  def handle_info({:x_socket, socket, {:frame, frame}}, %{socket: socket} = state),
    do: {:noreply, on_frame(frame, state)}

  def handle_info({:x_socket, socket, {:closed, reason}}, %{socket: socket} = state) do
    {:noreply, %{state | close_reason: state.close_reason || reason}}
  end

  def handle_info({:x_socket, _stale, _event}, state), do: {:noreply, state}

  def handle_info({:EXIT, socket, reason}, %{socket: socket} = state) when is_pid(socket),
    do: {:noreply, on_socket_exit(state.close_reason || reason, state)}

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{socket: socket}) when is_pid(socket) do
    Process.exit(socket, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- dialing ---------------------------------------------------------------

  defp dial(state) do
    url = url(state.record)

    with {:ok, opts} <- start_options(url, socket_options(state)),
         {:ok, socket} <- state.socket_module.start_link(url, %{owner: self()}, opts) do
      Pump.connection(:connecting, state.pump)
      %{state | socket: socket, phase: :connecting, close_reason: nil}
    else
      {:error, :proxy_unsupported_transport} ->
        Logger.error(
          "X: Fermix Connect is not connected: its socket cannot use the outbound proxy. " <>
            "List #{URI.parse(url).host} in [fermix_core.network] proxy_bypass if this " <>
            "machine reaches it directly, then restart."
        )

        refuse(:proxy_unsupported_transport, state)

      {:error, reason} ->
        lost(reason, state)
    end
  end

  # Caller options first, then the route, the upgrade headers and the async
  # start, then (in `start_options/2`) TLS: nothing earlier can override what
  # follows it.
  defp socket_options(state) do
    headers = [
      {"X-Fermix-Instance", state.record.instance_id},
      {"X-Fermix-Key-Id", state.record.key_id},
      {"Sec-WebSocket-Protocol", @subprotocol}
    ]

    state.socket_options
    |> Keyword.put(:egress, state.egress)
    |> Keyword.put(:extra_headers, headers)
    |> Keyword.put(:async, true)
    |> Keyword.put(:handle_initial_conn_failure, true)
  end

  # --- frames ----------------------------------------------------------------

  defp on_frame(%{"t" => "challenge", "nonce" => nonce}, %{phase: :connecting} = state)
       when is_binary(nonce) do
    with true <- Regex.match?(@nonce, nonce),
         {:ok, signature} <- Pairing.sign(session_message(state.record, nonce), state.pairing),
         :ok <- state.socket_module.send_json(state.socket, hello(signature)) do
      %{state | phase: :authenticating}
    else
      failure ->
        Logger.error("X: could not answer Connect's challenge: #{inspect(failure)}; closing")
        state.socket_module.close(state.socket)
        state
    end
  end

  defp on_frame(%{"t" => "ready"} = frame, %{phase: :authenticating} = state) do
    case limits(frame) do
      {:ok, ttl_s, limits} -> ready(ttl_s, limits, state)
      :error -> malformed_ready(state)
    end
  end

  defp on_frame(frame, %{phase: :ready} = state) do
    Pump.frame(frame, state.pump)
    state
  end

  defp on_frame(%{"t" => type}, state) do
    Logger.warning("X: Connect sent #{inspect(type)} before the session was ready; ignored")
    state
  end

  defp hello(signature) do
    Jason.encode!(%{
      "t" => "hello",
      "protocol_version" => @protocol_version,
      "signature" => Base.url_encode64(signature, padding: false),
      "capabilities" => %{"final_only" => true, "max_result_bytes" => @max_result_bytes}
    })
  end

  defp limits(%{
         "session_ttl_s" => ttl_s,
         "max_assignment_bytes" => assignment_bytes,
         "max_result_bytes" => result_bytes
       })
       when is_integer(ttl_s) and ttl_s > 0 and is_integer(assignment_bytes) and
              assignment_bytes > 0 and is_integer(result_bytes) and result_bytes > 0 do
    {:ok, ttl_s, %{max_assignment_bytes: assignment_bytes, max_result_bytes: result_bytes}}
  end

  defp limits(_frame), do: :error

  defp ready(ttl_s, limits, state) do
    Logger.info("X: connected to Fermix Connect")
    if state.degraded?, do: ChannelTelemetry.emit_transport(:x, :recovered, 0, :connected)
    Pump.connection({:connected, limits}, state.pump)

    ttl_ms = ttl_s * 1_000
    early = state.jitter.(div(ttl_ms, @ttl_jitter_share))
    timer = Process.send_after(self(), :session_ttl, max(ttl_ms - early, 0))
    %{state | phase: :ready, failures: 0, degraded?: false, ttl_timer: timer}
  end

  defp malformed_ready(state) do
    Logger.error("X: Connect's ready frame was malformed; closing")
    state.socket_module.close(state.socket)
    state
  end

  # --- losing the socket -----------------------------------------------------

  defp on_socket_exit(reason, state) do
    cancel_ttl(state)
    state = %{state | socket: nil, ttl_timer: nil, close_reason: nil}

    case close_class(reason) do
      :session_ttl -> redial(@reconnect_after_ttl_ms, %{state | phase: :waiting})
      {:refused, why} -> refuse(why, state)
      :lost -> lost(reason, state)
    end
  end

  defp close_class(:session_ttl), do: :session_ttl
  defp close_class({:remote, 4401, _message}), do: {:refused, :revoked}
  defp close_class({:remote, 4409, _message}), do: {:refused, :replaced}
  defp close_class(_reason), do: :lost

  defp refuse(why, state) do
    Logger.error("X: Fermix Connect refused this installation (#{why}); not reconnecting")
    ChannelTelemetry.emit_transport(:x, :degraded, state.failures, why)
    Pump.connection({:refused, why}, state.pump)
    %{state | phase: {:refused, why}, degraded?: true}
  end

  defp lost(reason, state) do
    failures = state.failures + 1
    Logger.warning("X: the Connect socket is down (#{inspect(reason)}); retry #{failures}")

    if not state.degraded?,
      do: ChannelTelemetry.emit_transport(:x, :degraded, failures, :connection_lost)

    Pump.connection(:down, state.pump)

    redial(backoff(failures, state.jitter), %{
      state
      | failures: failures,
        degraded?: true,
        phase: :waiting
    })
  end

  # Exponential from the base to the ceiling, then the ceiling for as long as
  # the channel runs; the second half of each delay is random, so installations
  # that lost Connect together do not return together.
  defp backoff(failures, jitter) do
    exponent = min(failures - 1, 6)
    delay = min(@backoff_base_ms * Integer.pow(2, exponent), @backoff_ceiling_ms)
    half = div(delay, 2)
    half + jitter.(half)
  end

  defp redial(delay_ms, state) do
    Process.send_after(self(), :connect, delay_ms)
    state
  end

  defp cancel_ttl(%{ttl_timer: nil}), do: :ok
  defp cancel_ttl(%{ttl_timer: timer}), do: Process.cancel_timer(timer)

  defp default_jitter(max) when is_integer(max) and max > 0, do: :rand.uniform(max + 1) - 1
  defp default_jitter(_max), do: 0
end
