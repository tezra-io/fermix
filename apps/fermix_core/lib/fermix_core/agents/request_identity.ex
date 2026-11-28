defmodule FermixCore.Agents.RequestIdentity do
  @moduledoc """
  One owner request's identity (M94 §06): what a tool whose side effect
  outlives the turn records as "the request that asked for it", so a repeated
  invocation inside that request finds the work it already started and a new
  request never does.

  Minted where a request's tool context is built, and nowhere else: once per
  turn by `Agents.TurnRunner` (a chat turn, a Live voice hand-off) and once per
  function call by `Realtime.ToolBridge` (a voice session that runs tools
  itself and keeps one session id for the whole conversation). Every tool call
  inside that context shares it, and `Capabilities.AccessGate` keeps it in a
  parked call's snapshot, so a confirmed call is still the same request. A
  request the grant resume re-runs after the owner's `/confirm` keeps it too:
  `TurnRunner` takes the one the resume hands back instead of minting.

  Random and unique for the life of the home, never a per-boot counter: a
  session id (`"main-<n>"`, `"voice_delegation_<n>"`, `"session:<n>"`) restarts
  at every boot or spans a whole conversation, so it cannot tell two requests
  apart.
  """

  @prefix "req_"
  @bytes 12

  @doc "A fresh request identity: `\"req_\"` + 24 lowercase hex characters."
  @spec mint() :: String.t()
  def mint, do: @prefix <> Base.encode16(:crypto.strong_rand_bytes(@bytes), case: :lower)

  @doc "Whether `value` has the shape of a minted request identity."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: Regex.match?(~r/\Areq_[0-9a-f]{24}\z/, value)
  def valid?(_value), do: false
end
