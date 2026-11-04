defmodule FermixChannels.Home.EnrollmentResponder do
  @moduledoc """
  The primary's responder for a candidate's enrollment (`FXM1 0x03`, Noise
  `IKpsk2`, M75 §7.1): the PSK is the window's secret
  (`FermixChannels.Home.Enrollment`) and the responder's static key the
  gateway key.

  `IKpsk2` mixes the PSK in at the end of the responder's message, so the
  handshake alone proves nothing about the initiator: its first transport
  frame, which only decrypts under keys derived from the PSK, is the proof.
  That frame burns the window; one that does not decrypt (a wrong secret)
  closes the stream `1002` and leaves the window as it was. A window already
  used by another candidate, or past its thirty minutes, answers the proven
  frame with `error` `enrollment_used` or `enrollment_expired` and closes
  `4003`; the candidate that used it (the same key, its answer lost) is
  answered `enroll_accepted` again with the id it was given. The
  candidate's `enroll_request` (within 10 s of the handshake, or the stream
  closes `1008`) is recorded and answered `enroll_accepted {candidate_id,
  primary_name}`, closing `1000`; a primary that already holds four
  candidates answers `enrollment_limit` instead. `ping` is answered `pong`;
  any other event the enrollment kind may not send, `unsupported_event`
  (`Mobile.Peers`).

  Options: `:enrollment` (the window's server), `:schedule` (a 2-arity timer,
  for tests), and the session's `:load_gateway_keypair` and `:peer`.
  """

  @behaviour FermixChannels.Home.Responder

  require Logger

  alias FermixChannels.Home.Enrollment
  alias FermixChannels.Home.ResponderWire

  @deadline_ms 10_000
  @refusals %{
    used: {"enrollment_used", "enrollment used", "That enrollment code was already used."},
    expired:
      {"enrollment_expired", "enrollment expired",
       "That enrollment code expired; open a new one on the primary."},
    limit:
      {"enrollment_limit", "enrollment limit",
       "The primary already holds four candidates; move to one, or wait for them to expire."}
  }

  @impl true
  def serving?(opts), do: opts |> server() |> Enrollment.window?()

  @impl true
  def init(wire, opts) do
    server = server(opts)

    with {:ok, secret} <- Enrollment.secret(server),
         {:ok, keypair} <- gateway_keypair(opts),
         {:ok, reply, session, remote} <-
           ResponderWire.handshake(
             :ikpsk2_enroll,
             wire,
             keypair_opts(keypair, secret),
             :enrollment
           ) do
      state = %{server: server, wire: session, remote: remote, timer: nil, proven?: false}
      {:push, [reply], arm(state, opts)}
    else
      :none -> {:stop, :no_window, {1002, "mobile protocol error"}, %{timer: nil}}
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, %{timer: nil}}
    end
  end

  defp keypair_opts(keypair, secret), do: [static_keypair: keypair, psk: secret]

  @impl true
  def handle_frame(ciphertext, state) do
    case ResponderWire.read(state.wire, ciphertext) do
      {:ok, event, wire} -> proven(%{state | wire: wire}, &handle_event(event, &1))
      {:refused, type, wire} -> proven(%{state | wire: wire}, &unsupported(type, &1))
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, state}
    end
  end

  # The first frame that decrypts proves the secret, and burns the window.
  defp proven(%{proven?: true} = state, next), do: next.(state)

  defp proven(state, next) do
    case Enrollment.take(state.server, state.remote) do
      :ok -> next.(%{state | proven?: true})
      {:error, reason} when reason in [:used, :expired] -> refuse(reason, state)
      {:error, :none} -> {:stop, :no_window, {1002, "mobile protocol error"}, state}
    end
  end

  @impl true
  def handle_info({:enrollment_deadline, token}, %{timer: {_ref, token}} = state),
    do: {:stop, :enrollment_deadline, {1008, "mobile handshake deadline"}, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{timer: {ref, _token}}) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def past_handshake?(%{proven?: proven?}), do: proven?
  def past_handshake?(_state), do: false

  defp handle_event(%{type: "enroll_request", payload: request}, state) do
    case Enrollment.enroll(state.server, request, state.remote) do
      {:ok, %{candidate_id: id, primary_name: name}} ->
        reply_and_stop(
          "enroll_accepted",
          %{"candidate_id" => id, "primary_name" => name},
          {:enrolled, id},
          {1000, "enrolled"},
          state
        )

      {:error, :limit} ->
        refuse(:limit, state)

      {:error, reason} ->
        Logger.error("enrollment: the candidate was not recorded: #{inspect(reason)}")
        {:stop, reason, {1011, "enrollment failed"}, state}
    end
  end

  defp handle_event(%{type: "ping"}, state) do
    case ResponderWire.write(state.wire, "pong", %{}) do
      {:ok, frames, wire} -> {:push, frames, %{state | wire: wire}}
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, state}
    end
  end

  defp unsupported(type, state) do
    message = "An enrollment session does not take #{type}."

    case ResponderWire.error(state.wire, "unsupported_event", message) do
      {:ok, frames, wire} -> {:push, frames, %{state | wire: wire}}
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, state}
    end
  end

  defp refuse(reason, state) do
    {code, close, sentence} = Map.fetch!(@refusals, reason)
    Logger.info("enrollment refused: #{code}")

    case ResponderWire.error(state.wire, code, sentence) do
      {:ok, frames, wire} ->
        {:stop, {:enrollment, reason}, {4003, close}, frames, %{state | wire: wire}}

      {:error, why} ->
        {:stop, why, {4003, close}, state}
    end
  end

  defp reply_and_stop(type, payload, why, close, state) do
    case ResponderWire.write(state.wire, type, payload) do
      {:ok, frames, wire} -> {:stop, why, close, frames, %{state | wire: wire}}
      {:error, reason} -> {:stop, reason, {1002, "mobile protocol error"}, state}
    end
  end

  defp arm(state, opts) do
    schedule = Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2))
    token = make_ref()
    %{state | timer: {schedule.({:enrollment_deadline, token}, @deadline_ms), token}}
  end

  defp gateway_keypair(opts) do
    case Keyword.fetch!(opts, :load_gateway_keypair).() do
      {:ok, %{private: <<_::256>> = private, public: <<_::256>> = public}} ->
        {:ok, %{private: private, public: public}}

      {:error, reason} ->
        {:error, {:gateway_identity_unavailable, reason}}
    end
  end

  defp server(opts), do: Keyword.get(opts, :enrollment, Enrollment)
end
