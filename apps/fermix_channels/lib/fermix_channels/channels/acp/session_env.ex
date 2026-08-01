defmodule FermixChannels.Channels.Acp.SessionEnv do
  @moduledoc """
  The client-session environment overlay: the bridge's spawn env, filtered on
  arrival to the internal allowlist and held as a closed struct
  (MILESTONE_29_ACP_AGENT_SURFACE.md §4/§8.3).

  The filter is the whole security value: everything the daemon does not name
  here is dropped **before** it is stored, so the operator's own secrets
  (`OPENAI_API_KEY`, cloud credentials, …) never enter session state at all. What
  survives is what a Buzz-spawned agent needs to answer in-channel — the relay
  address, the Buzz-owned signing keys, the harness PATH that makes its `buzz`
  CLI resolvable, and the git-over-relay credential variables.

  Custody is peer-parity, not invisibility (§8.3): a shell command the model runs
  in this session can read these values, exactly as claude/codex can under Buzz
  today. What this struct buys is that a *crash report* or a state dump never
  prints them — the `Inspect` implementation renders keys only. RAM-only,
  connection-scoped, never persisted.
  """

  @enforce_keys [:values]
  defstruct values: %{}

  @type t :: %__MODULE__{values: %{String.t() => String.t()}}

  # The allowlist (§4). Fixed keys plus the numbered `GIT_CONFIG_KEY_<n>` /
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

  @doc """
  Filter a raw process env to the allowlist. Non-string keys and values are
  dropped: an environment is strings, and anything else could not be handed to a
  child process anyway.
  """
  @spec new(map()) :: t()
  def new(env) when is_map(env) do
    %__MODULE__{values: env |> Enum.filter(&allowed?/1) |> Map.new()}
  end

  @doc "The plain map handed to a turn's message; the overlay's consumption form."
  @spec to_map(t()) :: %{String.t() => String.t()}
  def to_map(%__MODULE__{values: values}), do: values

  @doc "The overlay's key names, sorted — safe to log, unlike its values."
  @spec keys(t()) :: [String.t()]
  def keys(%__MODULE__{values: values}), do: values |> Map.keys() |> Enum.sort()

  defp allowed?({key, value}) when is_binary(key) and is_binary(value) do
    key in @allowed_keys or git_config_pair?(key)
  end

  defp allowed?(_entry), do: false

  defp git_config_pair?("GIT_CONFIG_KEY_" <> index), do: numeric?(index)
  defp git_config_pair?("GIT_CONFIG_VALUE_" <> index), do: numeric?(index)
  defp git_config_pair?(_key), do: false

  defp numeric?(index) do
    case Integer.parse(index) do
      {_number, ""} -> true
      _other -> false
    end
  end
end

defimpl Inspect, for: FermixChannels.Channels.Acp.SessionEnv do
  import Inspect.Algebra

  alias FermixChannels.Channels.Acp.SessionEnv

  # Renders key names and never values, so a GenServer crash report carrying a
  # Peer's state cannot print a Buzz signing key.
  def inspect(%SessionEnv{} = env, opts) do
    concat([
      "#Acp.SessionEnv<keys: ",
      to_doc(SessionEnv.keys(env), opts),
      ", values: redacted>"
    ])
  end
end
