defmodule FermixChannels.Home.ResponderWire do
  @moduledoc """
  The responder's side of the mobile wire for M75's own sessions (enrollment
  and the move): the Noise handshake, then frames held to the rules a phone's
  session holds (`fermix_core/priv/mobile/PROTOCOL.md`): each direction's
  REKEY after exactly 2^20 frames, the plaintext codec of `Mobile.Protocol`,
  client `seq` from 1 and one past the last, the version the first frame
  named, and the session kind's table of what it may send (`Mobile.Peers`).

  Pure: a value threaded through the responder's callbacks.
  """

  alias FermixChannels.Mobile.Noise
  alias FermixChannels.Mobile.Peers
  alias FermixChannels.Mobile.Protocol

  @rekey_after_frames 1_048_576

  @type t :: %{
          noise: Noise.State.t(),
          kind: Peers.kind(),
          client_seq: non_neg_integer(),
          server_seq: non_neg_integer(),
          version: pos_integer() | nil
        }

  @doc """
  Runs the responder's half of the handshake on the first wire: answers the
  reply to send, the session's wire and the initiator's static key.
  """
  @spec handshake(Noise.pattern(), binary(), keyword(), Peers.kind()) ::
          {:ok, binary(), t(), <<_::256>>} | {:error, term()}
  def handshake(pattern, wire, noise_opts, kind) when is_binary(wire) and is_list(noise_opts) do
    with {:ok, noise} <- Noise.initialize(:responder, pattern, noise_opts),
         {:ok, <<>>, noise} <- Noise.read_handshake(noise, wire),
         {:ok, reply, noise} <- Noise.write_handshake(noise, <<>>),
         {:ok, remote_static} <- Noise.remote_static(noise) do
      {:ok, reply, %{noise: noise, kind: kind, client_seq: 0, server_seq: 0, version: nil},
       remote_static}
    else
      {:ok, _payload, _noise} -> {:error, :invalid_handshake_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads one client frame: `{:ok, event, wire}`, `{:refused, type, wire}` for
  a known event the session's kind may not send (answered
  `unsupported_event`, the connection stays open), or `{:error, reason}`.
  """
  @spec read(t(), binary()) ::
          {:ok, Protocol.decoded_event(), t()} | {:refused, String.t(), t()} | {:error, term()}
  def read(wire, ciphertext) when is_binary(ciphertext) do
    with {:ok, noise} <- rekey_due(wire.noise, :receive),
         {:ok, plaintext, noise} <- Noise.decrypt(noise, ciphertext),
         {:ok, event} <- Protocol.decode_client_frame(plaintext),
         :ok <- in_sequence(event, wire) do
      wire = %{wire | noise: noise, client_seq: event.seq, version: event.version}

      case Peers.authorize(wire.kind, event.type) do
        :ok -> {:ok, event, wire}
        {:error, {:unsupported_event, type}} -> {:refused, type, wire}
      end
    end
  end

  @doc "Encodes and encrypts one server event as the frames it needs."
  @spec write(t(), String.t(), map(), binary()) :: {:ok, [binary()], t()} | {:error, term()}
  def write(wire, type, payload, bytes \\ <<>>) when is_binary(type) and is_map(payload) do
    true = Peers.server_event?(wire.kind, type)
    version = wire.version || Protocol.protocol_version()

    with {:ok, plaintexts} <-
           Protocol.encode_server_event(type, payload, wire.server_seq + 1, bytes,
             version: version
           ) do
      seal(plaintexts, %{wire | server_seq: wire.server_seq + length(plaintexts)}, [])
    end
  end

  @doc "The frames of an `error` event with `code` and a sentence."
  @spec error(t(), String.t(), String.t()) :: {:ok, [binary()], t()} | {:error, term()}
  def error(wire, code, message),
    do: write(wire, "error", %{"code" => code, "message" => message})

  defp seal([], wire, sealed), do: {:ok, Enum.reverse(sealed), wire}

  defp seal([plaintext | rest], wire, sealed) do
    with {:ok, noise} <- rekey_due(wire.noise, :send),
         {:ok, ciphertext, noise} <- Noise.encrypt(noise, plaintext) do
      seal(rest, %{wire | noise: noise}, [ciphertext | sealed])
    end
  end

  defp in_sequence(%{seq: seq, version: version}, wire) do
    cond do
      seq != wire.client_seq + 1 -> {:error, {:seq, seq, wire.client_seq + 1}}
      wire.version not in [nil, version] -> {:error, {:version, version}}
      true -> :ok
    end
  end

  # Each direction rekeys once it has carried exactly 2^20 frames under its
  # key, as `Mobile.Rail` and a phone's session do.
  defp rekey_due(noise, direction) do
    count = if direction == :send, do: noise.send_frames, else: noise.receive_frames
    if count >= @rekey_after_frames, do: Noise.rekey(noise, direction), else: {:ok, noise}
  end
end
