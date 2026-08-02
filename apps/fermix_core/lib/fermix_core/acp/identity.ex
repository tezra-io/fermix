defmodule FermixCore.Acp.Identity do
  @moduledoc """
  A client-presented ACP identity: the connected provider a Buzz-managed agent
  hands the daemon at hello (`MILESTONE_29_ACP_AGENT_SURFACE.md` §17.1–17.2).

  The record is the *only* producer of a turn's `session_env` — `to_env/1` — so
  the allowlist is enforced on the way in (`new/1`) and the shape is regenerated
  on the way out. Nothing outside the allowlist can reach a turn, and nothing
  the client set outside it is ever stored.

  ## The drop rule (§17.2), which everything downstream assumes

  The allowlist filters by key *name*, so a malformed signing key passes it
  untouched. "The env carries a `BUZZ_PRIVATE_KEY`" — the cheap question the
  harness advertise gate asks — would then disagree with "an id was derivable" —
  the question persistence, the ledger snapshot and the continuation ask.

  So `new/1` **drops `BUZZ_PRIVATE_KEY` and `NOSTR_PRIVATE_KEY` when no id is
  derivable**. A record carries a key *iff* it has an id, by construction, and
  the two questions have one answer. An unusable signing secret is not worth
  carrying into a turn: keeping it would only buy a `buzz` call that fails at
  the relay after minutes of work.

  ## Redaction

  Values are never rendered. The `Inspect` implementation prints key names only,
  so a crash report carrying a Peer's state cannot print a Buzz signing key. The
  `id` is rendered because it is a public key — `Nostr.Key.npub/1` is its
  display form on operator-facing surfaces (doctor rows, the consent log).
  """

  require Logger

  alias FermixCore.Nostr.Key

  # The §4 allowlist. Fixed names plus the numbered `GIT_CONFIG_KEY_<n>` /
  # `GIT_CONFIG_VALUE_<n>` pairs, whose count is client-chosen and so is matched
  # rather than enumerated.
  @allowed_keys ~w(
    BUZZ_RELAY_URL
    BUZZ_PRIVATE_KEY
    BUZZ_AUTH_TAG
    BUZZ_ACP_DISPLAY_NAME
    NOSTR_PRIVATE_KEY
    GIT_TERMINAL_PROMPT
    GIT_CONFIG_COUNT
    PATH
  )

  @secret_keys ~w(BUZZ_PRIVATE_KEY NOSTR_PRIVATE_KEY)
  @git_keys ~w(GIT_TERMINAL_PROMPT GIT_CONFIG_COUNT)
  @signing_key "BUZZ_PRIVATE_KEY"

  defstruct id: nil,
            kind: :buzz,
            display_name: nil,
            relay_url: nil,
            auth_tag: nil,
            path: nil,
            git_config: %{},
            secrets: %{},
            first_seen: nil,
            last_seen: nil

  @type env :: %{String.t() => String.t()}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          kind: :buzz,
          display_name: String.t() | nil,
          relay_url: String.t() | nil,
          auth_tag: String.t() | nil,
          path: String.t() | nil,
          git_config: env(),
          secrets: env(),
          first_seen: DateTime.t() | nil,
          last_seen: DateTime.t() | nil
        }

  @doc """
  Build a record from a client's raw hello env.

  Filters to the allowlist, derives the id from `BUZZ_PRIVATE_KEY`, and applies
  the drop rule above. A present-but-underivable key gets one warning naming the
  reason; an absent one is the ordinary identity-less case and says nothing.
  """
  @spec new(map()) :: t()
  def new(env) when is_map(env) do
    allowed = filter(env)

    case id_from_env(allowed) do
      {:ok, id} -> build(allowed, id, Map.take(allowed, @secret_keys))
      {:error, {:missing, @signing_key}} -> build(allowed, nil, %{})
      {:error, reason} -> build_unusable(allowed, reason)
    end
  end

  defp build_unusable(env, reason) do
    warn_unusable(reason)
    build(env, nil, %{})
  end

  @doc """
  Regenerate the allowlist env a turn consumes. The single producer of a
  `session_env` on this surface (§17.1).
  """
  @spec to_env(t()) :: env()
  def to_env(%__MODULE__{} = identity) do
    %{
      "BUZZ_RELAY_URL" => identity.relay_url,
      "BUZZ_AUTH_TAG" => identity.auth_tag,
      "BUZZ_ACP_DISPLAY_NAME" => identity.display_name,
      "PATH" => identity.path
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(identity.git_config)
    |> Map.merge(identity.secrets)
  end

  @doc """
  Can a run launched under this env report its outcome back? True iff the env
  carries a non-empty signing key and a `PATH` — the two things the model's own
  `buzz` call needs (§17.6(a)).

  Cheap by design, and equivalent to asking the store *because* of the drop
  rule: a record carries a key iff it has an id, and `to_env/1` is the only
  producer of such a map.
  """
  @spec posting_capable?(env() | nil) :: boolean()
  def posting_capable?(nil), do: false

  def posting_capable?(env) when is_map(env),
    do: present?(env, @signing_key) and present?(env, "PATH")

  @doc """
  Derive the identity id — the x-only public key of `BUZZ_PRIVATE_KEY`, as
  lowercase hex.

  One definition, used by `new/1` at hello and by the harness ledger snapshot at
  launch (§17.4), so the two can never disagree about who a turn belongs to.
  """
  @spec id_from_env(map()) :: {:ok, String.t()} | {:error, term()}
  def id_from_env(env) when is_map(env) do
    case Map.get(env, @signing_key) do
      secret when is_binary(secret) and secret != "" -> derive_id(secret)
      _absent -> {:error, {:missing, @signing_key}}
    end
  end

  @doc "The record's env key names, sorted — safe to log, unlike its values."
  @spec env_keys(t()) :: [String.t()]
  def env_keys(%__MODULE__{} = identity),
    do: identity |> to_env() |> Map.keys() |> Enum.sort()

  defp derive_id(secret) do
    case Key.decode_secret(secret) do
      {:ok, raw} -> Key.public_hex(raw)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build(env, id, secrets) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %__MODULE__{
      id: id,
      kind: :buzz,
      display_name: Map.get(env, "BUZZ_ACP_DISPLAY_NAME"),
      relay_url: Map.get(env, "BUZZ_RELAY_URL"),
      auth_tag: Map.get(env, "BUZZ_AUTH_TAG"),
      path: Map.get(env, "PATH"),
      git_config: Map.new(Enum.filter(env, &git_entry?/1)),
      secrets: secrets,
      first_seen: now,
      last_seen: now
    }
  end

  defp warn_unusable(reason) do
    Logger.warning(
      "Acp.Identity: #{@signing_key} is not a usable signing key (#{inspect(reason)}); " <>
        "the connection proceeds without an identity"
    )
  end

  defp filter(env), do: Map.new(Enum.filter(env, &allowed?/1))

  defp allowed?({key, value}) when is_binary(key) and is_binary(value),
    do: key in @allowed_keys or git_config_pair?(key)

  defp allowed?(_entry), do: false

  defp git_entry?({key, _value}), do: key in @git_keys or git_config_pair?(key)

  defp git_config_pair?("GIT_CONFIG_KEY_" <> index), do: numeric?(index)
  defp git_config_pair?("GIT_CONFIG_VALUE_" <> index), do: numeric?(index)
  defp git_config_pair?(_key), do: false

  defp numeric?(index) do
    case Integer.parse(index) do
      {_number, ""} -> true
      _other -> false
    end
  end

  defp present?(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) -> value != ""
      _absent -> false
    end
  end
end

defimpl Inspect, for: FermixCore.Acp.Identity do
  import Inspect.Algebra

  alias FermixCore.Acp.Identity

  # Key names and never values (ported verbatim from the rev-2 SessionEnv
  # discipline), so a GenServer crash report carrying a Peer's state cannot
  # print a Buzz signing key.
  def inspect(%Identity{} = identity, opts) do
    concat([
      "#Acp.Identity<id: ",
      to_doc(identity.id, opts),
      ", kind: ",
      to_doc(identity.kind, opts),
      ", keys: ",
      to_doc(Identity.env_keys(identity), opts),
      ", values: redacted>"
    ])
  end
end
