defmodule FermixChannels.X.Client.Socket do
  @moduledoc """
  The WebSocket to Fermix Connect, one per connection, linked to and owned by
  `X.Client`. It decodes each text frame into a map and hands it to its owner,
  and sends what its owner asks; every protocol decision is the owner's.

  It dials only a direct route: behind the outbound proxy, which a WebSocket
  cannot tunnel, `start_link/3` refuses with `:proxy_unsupported_transport`
  before any connection opens (`Net.Egress.ensure_direct/2`).

  When the connection ends, for any reason, the owner is told why and this
  process exits: reconnecting, with its backoff, is the owner's job, so a dead
  Connect is never redialed in a tight loop from here.
  """

  use WebSockex

  require Logger

  alias FermixCore.Net.Egress

  # Connect's own caps are 32 KiB for an assignment frame (§3.1); a text frame
  # past this is refused before it is decoded.
  @max_frame_bytes 1_048_576

  @type state :: %{owner: pid()}

  @doc "`opts` are WebSockex's, plus `:egress` (default: the active policy)."
  @spec start_link(String.t(), state(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(url, %{owner: owner} = state, opts)
      when is_binary(url) and is_pid(owner) and is_list(opts) do
    {egress, opts} = Keyword.pop_lazy(opts, :egress, &Egress.active/0)

    with :ok <- Egress.ensure_direct(url, egress) do
      WebSockex.start_link(url, __MODULE__, state, opts)
    end
  end

  @doc "Sends one JSON text frame; a socket that is gone answers an error."
  @spec send_json(pid(), String.t()) :: :ok | {:error, term()}
  def send_json(socket, json) when is_pid(socket) and is_binary(json) do
    WebSockex.send_frame(socket, {:text, json})
  catch
    :exit, reason -> {:error, {:socket_gone, reason}}
  end

  @doc "Closes the connection normally (the session's TTL)."
  @spec close(pid()) :: :ok
  def close(socket) when is_pid(socket), do: WebSockex.cast(socket, :close)

  @impl true
  def handle_frame({:text, payload}, state) when byte_size(payload) > @max_frame_bytes do
    Logger.error("X: Connect sent a #{byte_size(payload)}-byte frame, over the cap; closing")
    {:close, {4400, "frame over cap"}, state}
  end

  def handle_frame({:text, payload}, %{owner: owner} = state) do
    case Jason.decode(payload) do
      {:ok, %{"t" => type} = frame} when is_binary(type) ->
        send(owner, {:x_socket, self(), {:frame, frame}})

      _undecodable ->
        Logger.error("X: Connect sent a frame that is not a typed JSON object; ignored")
    end

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_disconnect(%{reason: reason}, %{owner: owner} = state) do
    send(owner, {:x_socket, self(), {:closed, reason}})
    {:ok, state}
  end
end
