defmodule FermixCore.Accessories.Attach do
  @moduledoc """
  The host's half of the accessory link's attach (`priv/accessory/PROTOCOL.md`,
  *Attach*; M91 D11, D14): a single-use challenge per HELLO, the checks on the
  accessory's `hello_ack` in the contract's order, and the host's own proof
  over the same transcript.

  A challenge carries the generation its `hello` opened, the host ID and
  capabilities, a fresh 32-byte nonce and a deadline ten seconds on. Any
  answer to it closes it, refused or not, so a nonce is used once; an answer
  of another generation is dropped and leaves it open, since the link fences
  stale messages by generation anyway. Time is the caller's monotonic
  milliseconds, passed in. Pure apart from the random nonce.
  """

  alias FermixCore.Accessories.Capabilities
  alias FermixCore.Accessories.Control
  alias FermixCore.Accessories.HostKey
  alias FermixCore.Accessories.P256
  alias FermixCore.Accessories.Record
  alias FermixCore.Accessories.Transcript

  @deadline_ms 10_000
  # The accessory honours at most one `hello` per 500 ms; the host sends at
  # most one a second, so a busy link is never a signing oracle.
  @min_hello_interval_ms 1_000
  # The kinds this host knows: the capabilities each must report, and the
  # metadata the daemon pins for it (M91 §04, D23), which the app renders and
  # keeps no table of its own for. A pin the kind's first firmware release has
  # not fixed yet is `:undecided`, never an invented value: the firmware range
  # its releases declare compatible, and the install guide's address on
  # fermix.ai.
  @kinds %{
    "stackchan" => %{
      required_capabilities: [:mic, :speaker],
      display_name: "StackChan",
      firmware_range: :undecided,
      install_guide: :undecided
    }
  }

  defmodule Challenge do
    @moduledoc "One `hello`'s single-use challenge."
    @enforce_keys [:gen, :host_id, :host_caps, :host_nonce, :opened_ms, :deadline_ms]
    defstruct @enforce_keys ++ [open?: true]

    @type t :: %__MODULE__{
            gen: pos_integer(),
            host_id: String.t(),
            host_caps: non_neg_integer(),
            host_nonce: <<_::256>>,
            opened_ms: integer(),
            deadline_ms: integer(),
            open?: boolean()
          }
  end

  defmodule Verified do
    @moduledoc "An accessory whose attach proof verified: what the link is now bound to."
    @enforce_keys [
      :gen,
      :accessory,
      :kind,
      :wire,
      :firmware,
      :pack,
      :host_caps,
      :accessory_caps,
      :caps,
      :transcript
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            gen: pos_integer(),
            accessory: Record.t(),
            kind: String.t(),
            wire: pos_integer(),
            firmware: String.t(),
            pack: String.t() | nil,
            host_caps: non_neg_integer(),
            accessory_caps: non_neg_integer(),
            caps: [Capabilities.name()],
            transcript: binary()
          }
  end

  @type refusal ::
          :stale_generation
          | :auth_timeout
          | :wire_version
          | :unsupported_kind
          | :capability_missing
          | :unknown_accessory
          | :bad_proof
  @type unenrolled :: %{
          kind: String.t(),
          firmware: String.t(),
          wire: pos_integer(),
          caps: non_neg_integer()
        }
  @type result ::
          {:ok, Verified.t()}
          | {:unenrolled, unenrolled()}
          | {:error, refusal()}
          | {:ignored, :stale_generation}

  @doc "How long an accessory has to answer a `hello`."
  @spec deadline_ms() :: pos_integer()
  def deadline_ms, do: @deadline_ms

  @doc "The kinds this host attaches."
  @spec kinds() :: [String.t()]
  def kinds, do: Map.keys(@kinds)

  @typedoc "What the daemon pins for a kind; `:undecided` where no release has fixed it yet."
  @type kind_metadata :: %{
          required_capabilities: [Capabilities.name()],
          display_name: String.t(),
          firmware_range: {String.t(), String.t()} | :undecided,
          install_guide: String.t() | :undecided
        }

  @doc "A kind's pinned metadata, or `:error` for a kind this host does not know."
  @spec kind_metadata(String.t()) :: {:ok, kind_metadata()} | :error
  def kind_metadata(kind) when is_binary(kind), do: Map.fetch(@kinds, kind)

  @doc "A new challenge for generation `gen`, opened at `now_ms`."
  @spec challenge(HostKey.t(), pos_integer(), integer(), <<_::256>>) :: Challenge.t()
  def challenge(%HostKey{} = host, gen, now_ms, nonce \\ :crypto.strong_rand_bytes(32))
      when gen in 1..4_294_967_295 and is_integer(now_ms) and byte_size(nonce) == 32 do
    %Challenge{
      gen: gen,
      host_id: host.id,
      host_caps: Capabilities.host(),
      host_nonce: nonce,
      opened_ms: now_ms,
      deadline_ms: now_ms + @deadline_ms
    }
  end

  @doc "The shortest time between two `hello`s the host sends."
  @spec min_hello_interval_ms() :: pos_integer()
  def min_hello_interval_ms, do: @min_hello_interval_ms

  @doc "Whether the host may send a new `hello` now, given the last challenge it opened."
  @spec may_hello?(Challenge.t() | nil, integer()) :: boolean()
  def may_hello?(nil, now_ms) when is_integer(now_ms), do: true

  def may_hello?(%Challenge{opened_ms: opened}, now_ms) when is_integer(now_ms),
    do: now_ms - opened >= @min_hello_interval_ms

  @doc "The `hello` that sends a challenge, for `Control.encode(:host, _)`."
  @spec hello(Challenge.t()) :: Control.message()
  def hello(%Challenge{} = challenge) do
    {wire_min, wire_max} = Control.supported_wire_range()

    %{
      type: "hello",
      gen: challenge.gen,
      wire_min: wire_min,
      wire_max: wire_max,
      host_id: challenge.host_id,
      host_nonce: challenge.host_nonce,
      caps: challenge.host_caps
    }
  end

  @doc """
  Checks a decoded `hello_ack` against the challenge and the enrolled
  accessories, in the contract's order; returns the verdict and the challenge,
  closed unless the answer was of another generation.
  """
  @spec verify(Challenge.t(), Control.message(), [Record.t()], integer()) ::
          {result(), Challenge.t()}
  def verify(%Challenge{} = challenge, %{type: "hello_ack", gen: gen} = ack, records, now_ms)
      when is_list(records) and is_integer(now_ms) do
    cond do
      gen != challenge.gen -> {{:ignored, :stale_generation}, challenge}
      not challenge.open? -> {{:error, :stale_generation}, challenge}
      true -> {checked(challenge, ack, records, now_ms), %{challenge | open?: false}}
    end
  end

  defp checked(challenge, ack, records, now_ms) do
    with :ok <- in_time(challenge, now_ms),
         :ok <- wire(ack.wire),
         {:ok, required} <- kind(ack.kind),
         :ok <- capabilities(ack.caps, required),
         {:ok, record} <- enrolled(ack, records) do
      proof(challenge, ack, record)
    end
  end

  defp in_time(%Challenge{deadline_ms: deadline}, now_ms) when now_ms < deadline, do: :ok
  defp in_time(_challenge, _now_ms), do: {:error, :auth_timeout}

  defp wire(wire) do
    {min, max} = Control.supported_wire_range()
    if wire in min..max//1, do: :ok, else: {:error, :wire_version}
  end

  defp kind(kind) do
    case Map.fetch(@kinds, kind) do
      {:ok, %{required_capabilities: required}} -> {:ok, required}
      :error -> {:error, :unsupported_kind}
    end
  end

  defp capabilities(caps, required) do
    if Capabilities.missing(caps, required) == [], do: :ok, else: {:error, :capability_missing}
  end

  defp enrolled(%{accessory_id: nil} = ack, _records),
    do: {:unenrolled, %{kind: ack.kind, firmware: ack.firmware, wire: ack.wire, caps: ack.caps}}

  defp enrolled(%{accessory_id: id}, records) do
    case Enum.find(records, &(&1.accessory_id == id)) do
      %Record{} = record -> {:ok, record}
      nil -> {:error, :unknown_accessory}
    end
  end

  defp proof(challenge, ack, record) do
    transcript = transcript(challenge, ack)

    if P256.verify(transcript, ack.sig, record.accessory_pk),
      do: {:ok, verified(challenge, ack, record, transcript)},
      else: {:error, :bad_proof}
  end

  defp transcript(challenge, ack) do
    Transcript.attach(%{
      host_id: challenge.host_id,
      accessory_id: ack.accessory_id,
      host_nonce: challenge.host_nonce,
      accessory_nonce: ack.accessory_nonce,
      wire: ack.wire,
      host_caps: challenge.host_caps,
      accessory_caps: ack.caps,
      gen: challenge.gen,
      kind: ack.kind
    })
  end

  defp verified(challenge, ack, record, transcript) do
    %Verified{
      gen: challenge.gen,
      accessory: record,
      kind: ack.kind,
      wire: ack.wire,
      firmware: ack.firmware,
      pack: ack.pack,
      host_caps: challenge.host_caps,
      accessory_caps: ack.caps,
      caps: Capabilities.effective(challenge.host_caps, ack.caps),
      transcript: transcript
    }
  end

  @doc "The host's proof for a verified attach: its signature over the same transcript."
  @spec host_proof(Verified.t(), HostKey.t()) :: Control.message()
  def host_proof(%Verified{} = verified, %HostKey{} = host),
    do: %{
      type: "host_proof",
      gen: verified.gen,
      sig: P256.sign(verified.transcript, host.private)
    }
end
