defmodule FermixCore.PhoneCalls.CarrierProfile do
  @moduledoc """
  The one carrier configuration phone calls are certified for (M94 §3): the
  owner's own Telnyx credential connection, dialed out by GPT-Live.

  Every value here is a constant of the engine, never a setting. The trunk
  address above all: the owner types the connection's username and password,
  never a host, so OpenAI is only ever told to present that password to
  Telnyx. Telnyx signs TLS for `sip.telnyx.com` on port 5061, and OpenAI's
  create request takes the trunk as `sips:host[:port]`, so the address is
  `sips:sip.telnyx.com:5061`.

  The model is pinned, not followed: a call runs on the model this profile was
  certified with, so a newer Live model reaches phone calls only through a
  change here. It must be one the Live engine ships, which compilation checks
  against `Realtime.Config`, the engine's one model and voice catalog.
  """

  alias FermixCore.Realtime.Config, as: RealtimeConfig

  @id "telnyx_credential_v1"
  @trunk_address "sips:sip.telnyx.com:5061"
  # The `Realtime.Config` engine whose catalog holds the model and the voices.
  @voice_engine "openai_live"
  @model "gpt-live-1"

  unless @model in RealtimeConfig.valid_models(@voice_engine) do
    raise CompileError,
      description: "CarrierProfile: #{@model} is not a model the #{@voice_engine} engine ships"
  end

  @doc "The certified profile's id, which each admitted call records."
  @spec id() :: String.t()
  def id, do: @id

  @doc "The trunk OpenAI dials out through: `trunk.provider_url` in the create request."
  @spec trunk_address() :: String.t()
  def trunk_address, do: @trunk_address

  @doc "The Live model a phone call runs on."
  @spec model() :: String.t()
  def model, do: @model

  @doc "The engine whose voice catalog (`Realtime.Config.valid_voices/1`) phone voices come from."
  @spec voice_engine() :: String.t()
  def voice_engine, do: @voice_engine
end
