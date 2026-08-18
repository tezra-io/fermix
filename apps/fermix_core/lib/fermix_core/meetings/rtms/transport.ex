defmodule FermixCore.Meetings.Rtms.Transport do
  @moduledoc """
  The three RTMS sockets as one narrow, injectable seam.

  `RtmsSource` owns three outbound WebSockets at once (event, signaling, media)
  and must tell their traffic apart, so every message carries the leg's tag. The
  behaviour exists so the source's whole state machine can be driven in `mix
  test` by a scripted transport: no live Zoom socket ever opens in the suite.

  ## Messages to the owner

  | Message | Meaning |
  |---|---|
  | `{:rtms_ws, tag, {:message, map()}}` | one decoded JSON frame from that leg |
  | `{:rtms_ws, tag, {:message, binary()}}` | one binary frame from that leg |
  | `{:rtms_ws, tag, {:closed, reason}}` | that leg is gone — terminal, there is no reconnect |

  `tag` is `:event`, `:signaling`, or `:media`.
  """

  @typedoc "Which of the three legs a connection is."
  @type tag :: :event | :signaling | :media

  @typedoc "Whatever the implementation needs to send on and close a leg."
  @type conn :: term()

  @doc """
  Opens `url` and streams frames to `owner`.

  `opts` carries `:tag` (required — it labels every message) and
  `:connect_timeout_ms`.
  """
  @callback connect(url :: String.t(), owner :: pid(), opts :: keyword()) ::
              {:ok, conn()} | {:error, term()}

  @doc "Encodes `payload` as JSON and sends it as a text frame."
  @callback send_json(conn :: conn(), payload :: map()) :: :ok | {:error, term()}

  @doc "Closes the leg. Idempotent — closing an already-dead leg is `:ok`."
  @callback close(conn :: conn()) :: :ok
end

defmodule FermixCore.Meetings.Rtms.Transport.WebSockex do
  @moduledoc """
  The production `Rtms.Transport`: one `WebSockex` process per leg.

  Deliberately dumb. It decodes JSON, tags the frame with its leg, and forwards
  it — every protocol judgement lives in `Rtms.Protocol` and every state
  decision in `RtmsSource`. A frame that is not decodable JSON closes the leg
  rather than being skipped: RTMS carries no optional text traffic, so an
  undecodable frame means we are no longer reading the stream we think we are.

  There is no reconnect. `WebSockex` is started without a reconnect strategy, so
  a dropped leg terminates the socket process after the owner has been told —
  which is the v1 posture for the whole lane (a dropped leg is terminal for the
  meeting, and the Session finalizes whatever was captured).
  """

  use WebSockex

  @behaviour FermixCore.Meetings.Rtms.Transport

  @default_connect_timeout_ms 10_000

  @impl FermixCore.Meetings.Rtms.Transport
  @spec connect(String.t(), pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(url, owner, opts) when is_binary(url) and is_pid(owner) and is_list(opts) do
    tag = Keyword.fetch!(opts, :tag)
    timeout = Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms)

    WebSockex.start_link(url, __MODULE__, %{owner: owner, tag: tag},
      handshake_timeout: timeout,
      async: false
    )
  end

  @impl FermixCore.Meetings.Rtms.Transport
  @spec send_json(pid(), map()) :: :ok | {:error, term()}
  def send_json(conn, payload) when is_pid(conn) and is_map(payload) do
    with {:ok, json} <- Jason.encode(payload) do
      WebSockex.send_frame(conn, {:text, json})
    end
  end

  @impl FermixCore.Meetings.Rtms.Transport
  @spec close(pid()) :: :ok
  def close(conn) when is_pid(conn) do
    if Process.alive?(conn), do: WebSockex.cast(conn, :close)
    :ok
  end

  @impl true
  def handle_frame({:text, payload}, state) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, message} ->
        notify(state, {:message, message})
        {:ok, state}

      {:error, reason} ->
        notify(state, {:closed, {:undecodable_frame, Exception.message(reason)}})
        {:close, state}
    end
  end

  def handle_frame({:binary, payload}, state) do
    notify(state, {:message, payload})
    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast(:close, state), do: {:close, state}

  @impl true
  def handle_disconnect(status, state) do
    notify(state, {:closed, status})
    {:ok, state}
  end

  defp notify(%{owner: owner, tag: tag}, event), do: send(owner, {:rtms_ws, tag, event})
end
