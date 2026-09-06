defmodule FermixChannels.Mobile.Noise do
  @moduledoc """
  Noise `IK` and `IKpsk2` for the mobile channel, implemented over OTP `:crypto`.

  The five-byte clear prelude selects exactly one mode before responder state is
  initialized: `<<"FXM1", 1>>` for an already-paired `IK` session and
  `<<"FXM1", 2>>` for the one-time-secret `IKpsk2` pairing ceremony. The
  selected prelude is also bound into the Noise prologue, so it is authenticated
  by the transcript. There is no alternate-handshake attempt.
  """

  alias FermixChannels.Mobile.Noise.Cipher
  alias FermixChannels.Mobile.Noise.Symmetric

  @paired_prelude <<"FXM1", 1>>
  @pairing_prelude <<"FXM1", 2>>
  @prologue_prefix "fermix-mobile-v1"
  @sas_label "fermix-mobile-sas-v1"
  @max_noise_message_bytes 65_535
  @max_transport_plaintext_bytes @max_noise_message_bytes - 16
  @zero_key :binary.copy(<<0>>, 32)

  defmodule State do
    @moduledoc false

    @enforce_keys [:role, :pattern, :step, :static_keypair, :ephemeral_keypair, :psk]
    defstruct [
      :role,
      :pattern,
      :step,
      :static_keypair,
      :ephemeral_keypair,
      :remote_static,
      :remote_ephemeral,
      :psk,
      :symmetric,
      :handshake_hash,
      :send_cipher,
      :receive_cipher,
      complete?: false,
      send_frames: 0,
      receive_frames: 0
    ]

    @type keypair :: %{private: binary(), public: binary()}

    @type t :: %__MODULE__{
            role: :initiator | :responder,
            pattern: :ik | :ikpsk2,
            step: 0..2,
            static_keypair: keypair() | nil,
            ephemeral_keypair: keypair() | nil,
            remote_static: binary() | nil,
            remote_ephemeral: binary() | nil,
            psk: binary() | nil,
            symmetric: Symmetric.t() | nil,
            handshake_hash: binary() | nil,
            send_cipher: Cipher.t() | nil,
            receive_cipher: Cipher.t() | nil,
            complete?: boolean(),
            send_frames: non_neg_integer(),
            receive_frames: non_neg_integer()
          }
  end

  @type pattern :: :ik | :ikpsk2
  @type role :: :initiator | :responder
  @type keypair :: State.keypair()

  @doc "The fixed outer prelude for paired-device IK sessions."
  @spec paired_prelude() :: binary()
  def paired_prelude, do: @paired_prelude

  @doc "The fixed outer prelude for IKpsk2 pairing sessions."
  @spec pairing_prelude() :: binary()
  def pairing_prelude, do: @pairing_prelude

  @doc "The authenticated Noise prologue for a selected mode."
  @spec prologue(pattern()) :: binary()
  def prologue(:ik), do: @prologue_prefix <> @paired_prelude
  def prologue(:ikpsk2), do: @prologue_prefix <> @pairing_prelude

  @doc "Parse and validate the clear mode prelude without initializing Noise state."
  @spec parse_prelude(binary(), pattern() | :any) ::
          {:ok, pattern(), binary()} | {:error, term()}
  def parse_prelude(<<"FXM1", mode, rest::binary>>, expected) do
    with {:ok, pattern} <- pattern_for_mode(mode),
         :ok <- expected_pattern(pattern, expected) do
      {:ok, pattern, rest}
    end
  end

  def parse_prelude(_wire, _expected), do: {:error, :invalid_prelude}

  @doc "Generate an X25519 keypair using OTP's cryptographically secure RNG."
  @spec generate_keypair() :: keypair()
  def generate_keypair do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    %{private: private, public: public}
  end

  @doc "Derive and validate an X25519 keypair from a 32-byte private key."
  @spec keypair_from_private(binary()) :: {:ok, keypair()} | {:error, term()}
  def keypair_from_private(<<private::binary-size(32)>>) do
    {public, ^private} = :crypto.generate_key(:ecdh, :x25519, private)
    {:ok, %{private: private, public: public}}
  end

  def keypair_from_private(_private), do: {:error, :invalid_private_key}

  @doc "Initialize an initiator or a staged responder handshake."
  @spec initialize(role(), pattern(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def initialize(role, pattern, opts)
      when role in [:initiator, :responder] and pattern in [:ik, :ikpsk2] and is_list(opts) do
    with {:ok, static} <- required_keypair(opts, :static_keypair),
         {:ok, ephemeral} <- optional_ephemeral(opts),
         {:ok, psk} <- validate_psk(pattern, Keyword.get(opts, :psk)),
         {:ok, remote_static} <- remote_static(role, opts) do
      state = %State{
        role: role,
        pattern: pattern,
        step: 0,
        static_keypair: static,
        ephemeral_keypair: ephemeral,
        remote_static: remote_static,
        psk: psk
      }

      initialize_role(state)
    end
  end

  @doc "Write the next handshake message and advance the state once."
  @spec write_handshake(State.t(), binary()) ::
          {:ok, binary(), State.t()} | {:error, term()}
  def write_handshake(%State{role: :initiator, step: 0} = state, payload)
      when is_binary(payload),
      do: write_initiator_first(state, payload)

  def write_handshake(%State{role: :responder, step: 1} = state, payload)
      when is_binary(payload),
      do: write_responder_second(state, payload)

  def write_handshake(%State{}, _payload), do: {:error, :invalid_handshake_state}

  @doc "Read the next handshake message and advance the state once."
  @spec read_handshake(State.t(), binary()) ::
          {:ok, binary(), State.t()} | {:error, term()}
  def read_handshake(%State{role: :responder, step: 0} = state, wire)
      when is_binary(wire),
      do: read_initiator_first(state, wire)

  def read_handshake(%State{role: :initiator, step: 1} = state, wire)
      when is_binary(wire),
      do: read_responder_second(state, wire)

  def read_handshake(%State{}, _wire), do: {:error, :invalid_handshake_state}

  @doc "True only after both handshake messages have authenticated successfully."
  @spec complete?(State.t()) :: boolean()
  def complete?(%State{} = state), do: state.complete?

  @doc "The authenticated final Noise handshake hash."
  @spec handshake_hash(State.t()) :: binary()
  def handshake_hash(%State{complete?: true, handshake_hash: hash}), do: hash

  @doc "Six-digit SAS derived from the final handshake hash."
  @spec sas(State.t()) :: String.t()
  def sas(%State{complete?: true} = state) do
    digest = :crypto.mac(:hmac, :sha256, handshake_hash(state), @sas_label)
    <<value::unsigned-big-32, _rest::binary>> = digest
    value |> rem(1_000_000) |> Integer.to_string() |> String.pad_leading(6, "0")
  end

  @doc "The authenticated initiator static key learned by a responder."
  @spec remote_static(State.t()) :: {:ok, binary()} | {:error, term()}
  def remote_static(%State{remote_static: <<key::binary-size(32)>>}), do: {:ok, key}
  def remote_static(%State{}), do: {:error, :remote_static_unavailable}

  @doc "Encrypt one post-handshake Noise transport message."
  @spec encrypt(State.t(), binary()) :: {:ok, binary(), State.t()} | {:error, term()}
  def encrypt(%State{complete?: true} = state, plaintext)
      when is_binary(plaintext) and byte_size(plaintext) <= @max_transport_plaintext_bytes do
    with {:ok, ciphertext, cipher} <- Cipher.encrypt(state.send_cipher, <<>>, plaintext) do
      {:ok, ciphertext, %{state | send_cipher: cipher, send_frames: state.send_frames + 1}}
    end
  end

  def encrypt(%State{complete?: true}, plaintext) when is_binary(plaintext),
    do: {:error, {:plaintext_too_large, byte_size(plaintext), @max_transport_plaintext_bytes}}

  def encrypt(%State{}, _plaintext), do: {:error, :handshake_incomplete}

  @doc "Decrypt and authenticate one post-handshake Noise transport message."
  @spec decrypt(State.t(), binary()) :: {:ok, binary(), State.t()} | {:error, term()}
  def decrypt(%State{complete?: true} = state, ciphertext)
      when is_binary(ciphertext) and byte_size(ciphertext) <= @max_noise_message_bytes do
    with {:ok, plaintext, cipher} <- Cipher.decrypt(state.receive_cipher, <<>>, ciphertext) do
      {:ok, plaintext,
       %{state | receive_cipher: cipher, receive_frames: state.receive_frames + 1}}
    end
  end

  def decrypt(%State{complete?: true}, ciphertext) when is_binary(ciphertext),
    do: {:error, {:ciphertext_too_large, byte_size(ciphertext), @max_noise_message_bytes}}

  def decrypt(%State{}, _ciphertext), do: {:error, :handshake_incomplete}

  @doc "Apply Noise REKEY to one transport direction and reset its frame count."
  @spec rekey(State.t(), :send | :receive) :: {:ok, State.t()} | {:error, term()}
  def rekey(%State{complete?: true} = state, :send) do
    with {:ok, cipher} <- Cipher.rekey(state.send_cipher) do
      {:ok, %{state | send_cipher: cipher, send_frames: 0}}
    end
  end

  def rekey(%State{complete?: true} = state, :receive) do
    with {:ok, cipher} <- Cipher.rekey(state.receive_cipher) do
      {:ok, %{state | receive_cipher: cipher, receive_frames: 0}}
    end
  end

  def rekey(%State{}, _direction), do: {:error, :handshake_incomplete}

  defp initialize_role(%State{role: :responder} = state), do: {:ok, state}

  defp initialize_role(%State{role: :initiator} = state) do
    symmetric = initialize_symmetric(state.pattern, state.remote_static)
    {:ok, %{state | symmetric: symmetric}}
  end

  defp write_initiator_first(state, payload) do
    %{ephemeral_keypair: ephemeral, static_keypair: static} = state
    symmetric = mix_ephemeral(state.symmetric, ephemeral.public, state.pattern)

    with {:ok, symmetric} <- mix_dh(symmetric, ephemeral.private, state.remote_static),
         {:ok, encrypted_static, symmetric} <-
           Symmetric.encrypt_and_hash(symmetric, static.public),
         {:ok, symmetric} <- mix_dh(symmetric, static.private, state.remote_static),
         {:ok, encrypted_payload, symmetric} <-
           Symmetric.encrypt_and_hash(symmetric, payload),
         {:ok, wire} <-
           bounded_handshake(
             prelude(state.pattern) <>
               ephemeral.public <> encrypted_static <> encrypted_payload,
             true
           ) do
      {:ok, wire, %{state | symmetric: symmetric, step: 1}}
    end
  end

  defp read_initiator_first(state, wire) do
    with {:ok, pattern, body} <- parse_prelude(wire, state.pattern),
         :ok <- bounded_handshake_input(body),
         symmetric = initialize_symmetric(pattern, state.static_keypair.public),
         {:ok, remote_ephemeral, rest} <- take(body, 32, :initiator_ephemeral),
         symmetric = mix_ephemeral(symmetric, remote_ephemeral, pattern),
         {:ok, symmetric} <-
           mix_dh(symmetric, state.static_keypair.private, remote_ephemeral),
         {:ok, encrypted_static, encrypted_payload} <- take(rest, 48, :initiator_static),
         {:ok, remote_static, symmetric} <-
           Symmetric.decrypt_and_hash(symmetric, encrypted_static),
         :ok <- validate_public_key(remote_static),
         {:ok, symmetric} <- mix_dh(symmetric, state.static_keypair.private, remote_static),
         {:ok, payload, symmetric} <-
           Symmetric.decrypt_and_hash(symmetric, encrypted_payload) do
      {:ok, payload,
       %{
         state
         | symmetric: symmetric,
           remote_ephemeral: remote_ephemeral,
           remote_static: remote_static,
           step: 1
       }}
    end
  end

  defp write_responder_second(state, payload) do
    ephemeral = state.ephemeral_keypair
    symmetric = mix_ephemeral(state.symmetric, ephemeral.public, state.pattern)

    with {:ok, symmetric} <- mix_dh(symmetric, ephemeral.private, state.remote_ephemeral),
         {:ok, symmetric} <- mix_dh(symmetric, ephemeral.private, state.remote_static),
         symmetric = mix_psk(symmetric, state.pattern, state.psk),
         {:ok, encrypted_payload, symmetric} <-
           Symmetric.encrypt_and_hash(symmetric, payload),
         {:ok, wire} <- bounded_handshake(ephemeral.public <> encrypted_payload, false) do
      finish_handshake(%{state | symmetric: symmetric, step: 2}, wire, payload)
    end
  end

  defp read_responder_second(state, wire) do
    with :ok <- bounded_handshake_input(wire),
         {:ok, remote_ephemeral, encrypted_payload} <-
           take(wire, 32, :responder_ephemeral),
         symmetric = mix_ephemeral(state.symmetric, remote_ephemeral, state.pattern),
         {:ok, symmetric} <-
           mix_dh(symmetric, state.ephemeral_keypair.private, remote_ephemeral),
         {:ok, symmetric} <-
           mix_dh(symmetric, state.static_keypair.private, remote_ephemeral),
         symmetric = mix_psk(symmetric, state.pattern, state.psk),
         {:ok, payload, symmetric} <-
           Symmetric.decrypt_and_hash(symmetric, encrypted_payload) do
      finish_handshake(
        %{state | symmetric: symmetric, remote_ephemeral: remote_ephemeral, step: 2},
        wire,
        payload
      )
    end
  end

  defp finish_handshake(state, wire, payload) do
    {first, second} = Symmetric.split(state.symmetric)
    {send_cipher, receive_cipher} = transport_ciphers(state.role, first, second)

    complete = %{
      state
      | complete?: true,
        send_cipher: send_cipher,
        receive_cipher: receive_cipher,
        handshake_hash: state.symmetric.handshake_hash,
        static_keypair: nil,
        ephemeral_keypair: nil,
        remote_ephemeral: nil,
        psk: nil,
        symmetric: nil
    }

    if state.role == :responder,
      do: {:ok, wire, complete},
      else: {:ok, payload, complete}
  end

  defp transport_ciphers(:initiator, first, second), do: {first, second}
  defp transport_ciphers(:responder, first, second), do: {second, first}

  defp initialize_symmetric(pattern, responder_static) do
    Symmetric.initialize(protocol_name(pattern), prologue(pattern), responder_static)
  end

  defp protocol_name(:ik), do: "Noise_IK_25519_ChaChaPoly_SHA256"
  defp protocol_name(:ikpsk2), do: "Noise_IKpsk2_25519_ChaChaPoly_SHA256"

  defp prelude(:ik), do: @paired_prelude
  defp prelude(:ikpsk2), do: @pairing_prelude

  defp mix_ephemeral(symmetric, public, :ik), do: Symmetric.mix_hash(symmetric, public)

  defp mix_ephemeral(symmetric, public, :ikpsk2) do
    symmetric |> Symmetric.mix_hash(public) |> Symmetric.mix_key(public)
  end

  defp mix_psk(symmetric, :ik, nil), do: symmetric
  defp mix_psk(symmetric, :ikpsk2, psk), do: Symmetric.mix_key_and_hash(symmetric, psk)

  defp mix_dh(symmetric, private, public) do
    with {:ok, shared} <- dh(private, public) do
      {:ok, Symmetric.mix_key(symmetric, shared)}
    end
  end

  defp dh(<<private::binary-size(32)>>, <<public::binary-size(32)>>) do
    case :crypto.compute_key(:ecdh, public, private, :x25519) do
      @zero_key -> {:error, :invalid_remote_key}
      <<shared::binary-size(32)>> -> {:ok, shared}
    end
  rescue
    ErlangError -> {:error, :invalid_remote_key}
  end

  defp required_keypair(opts, key) do
    opts |> Keyword.get(key) |> validate_keypair()
  end

  defp optional_ephemeral(opts) do
    case Keyword.get(opts, :ephemeral_keypair) do
      nil -> {:ok, generate_keypair()}
      keypair -> validate_keypair(keypair)
    end
  end

  defp validate_keypair(keypair) when is_map(keypair) do
    private = Map.get(keypair, :private) || Map.get(keypair, "private")
    public = Map.get(keypair, :public) || Map.get(keypair, "public")

    with <<_::binary-size(32)>> <- private,
         <<_::binary-size(32)>> <- public,
         {:ok, derived} <- keypair_from_private(private),
         true <- secure_equal?(derived.public, public) do
      {:ok, %{private: private, public: public}}
    else
      _invalid -> {:error, :invalid_keypair}
    end
  end

  defp validate_keypair(_keypair), do: {:error, :invalid_keypair}

  defp remote_static(:responder, _opts), do: {:ok, nil}

  defp remote_static(:initiator, opts) do
    case Keyword.get(opts, :remote_static) do
      <<key::binary-size(32)>> -> {:ok, key}
      _key -> {:error, :invalid_remote_static}
    end
  end

  defp validate_psk(:ik, nil), do: {:ok, nil}
  defp validate_psk(:ik, _psk), do: {:error, :psk_not_allowed}
  defp validate_psk(:ikpsk2, <<psk::binary-size(32)>>), do: {:ok, psk}
  defp validate_psk(:ikpsk2, _psk), do: {:error, :invalid_psk}

  defp validate_public_key(<<_key::binary-size(32)>>), do: :ok
  defp validate_public_key(_key), do: {:error, :invalid_remote_key}

  defp bounded_handshake(wire, has_prelude?) do
    noise_size = if has_prelude?, do: byte_size(wire) - 5, else: byte_size(wire)

    if noise_size <= @max_noise_message_bytes,
      do: {:ok, wire},
      else: {:error, {:handshake_message_too_large, noise_size, @max_noise_message_bytes}}
  end

  defp bounded_handshake_input(wire) do
    if byte_size(wire) <= @max_noise_message_bytes,
      do: :ok,
      else: {:error, {:handshake_message_too_large, byte_size(wire), @max_noise_message_bytes}}
  end

  defp take(bytes, size, _field) when byte_size(bytes) >= size do
    <<value::binary-size(size), rest::binary>> = bytes
    {:ok, value, rest}
  end

  defp take(_bytes, _size, field), do: {:error, {:truncated_handshake, field}}

  defp pattern_for_mode(1), do: {:ok, :ik}
  defp pattern_for_mode(2), do: {:ok, :ikpsk2}
  defp pattern_for_mode(_mode), do: {:error, :unknown_handshake_mode}

  defp expected_pattern(_pattern, :any), do: :ok
  defp expected_pattern(pattern, pattern), do: :ok
  defp expected_pattern(_pattern, _expected), do: {:error, :handshake_mode_mismatch}

  defp secure_equal?(left, right), do: :crypto.hash_equals(left, right)
end
