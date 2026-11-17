defmodule FermixCore.PhoneCalls.Readiness do
  @moduledoc """
  Whether this engine can place a phone call now (M94 §12, "Phone requested
  on, but its key/trunk is missing"): `:disabled` when the owner has phone
  calls off, `:ready`, or `{:needs_setup, reasons}` naming each missing
  requirement, with one sentence for the owner per reason (`sentence/1`).

  `decide/1` is the decision, over explicit inputs. `current/1` gathers those
  inputs from where they live: the section (`Config.get/0`), the OpenAI
  Platform key and the trunk password (`Config.openai_api_key/0`,
  `Config.sip_password/1`, the same reads the call's I/O boundary makes), the
  role this engine booted in (`Home.Role.booted/0`: only the primary dials),
  and whether durable memory is on (`Memory.Config.enabled?/0`: a call's record
  lives in `memory.db`). Each can be handed in instead, for a test.

  Readiness says nothing about a call in progress or an unresolved one; the
  call's own state does. A SpaceXAI key never makes phone calls ready.
  """

  alias FermixCore.Home.Role
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.PhoneCalls.Config

  @reasons [
    :not_primary,
    :durable_memory_off,
    :openai_api_key_missing,
    :caller_number_missing,
    :sip_username_missing,
    :sip_password_missing
  ]

  @type reason ::
          :not_primary
          | :durable_memory_off
          | :openai_api_key_missing
          | :caller_number_missing
          | :sip_username_missing
          | :sip_password_missing

  @type status :: :disabled | :ready | {:needs_setup, [reason(), ...]}

  @type inputs :: %{
          required(:config) => Config.t(),
          required(:openai_api_key?) => boolean(),
          required(:sip_password?) => boolean(),
          required(:primary?) => boolean(),
          required(:durable_memory?) => boolean()
        }

  @doc "Every reason, in the order `decide/1` lists them."
  @spec reasons() :: [reason(), ...]
  def reasons, do: @reasons

  @doc "Readiness over explicit inputs."
  @spec decide(inputs()) :: status()
  def decide(%{config: %Config{enabled: false}}), do: :disabled

  def decide(
        %{
          config: %Config{enabled: true} = config,
          openai_api_key?: key?,
          sip_password?: password?,
          primary?: primary?,
          durable_memory?: memory?
        } = inputs
      )
      when is_boolean(key?) and is_boolean(password?) and is_boolean(primary?) and
             is_boolean(memory?) do
    missing =
      Enum.filter(@reasons, fn reason -> missing?(reason, config, inputs) end)

    if missing == [], do: :ready, else: {:needs_setup, missing}
  end

  @doc """
  Readiness of the running engine. Any input `decide/1` takes may be given in
  `opts` (`:config`, `:openai_api_key?`, `:sip_password?`, `:primary?`,
  `:durable_memory?`); each one absent is read from its source.
  """
  @spec current(keyword()) :: status()
  def current(opts \\ []) when is_list(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.get/0)

    decide(%{
      config: config,
      openai_api_key?: Keyword.get_lazy(opts, :openai_api_key?, &openai_api_key?/0),
      sip_password?: Keyword.get_lazy(opts, :sip_password?, fn -> sip_password?(config) end),
      primary?: Keyword.get_lazy(opts, :primary?, &primary?/0),
      durable_memory?: Keyword.get_lazy(opts, :durable_memory?, &MemoryConfig.enabled?/0)
    })
  end

  @doc "The owner's sentence for one reason."
  @spec sentence(reason()) :: String.t()
  def sentence(:not_primary),
    do:
      "Phone calls are placed by the computer this home runs on, and this computer only " <>
        "connects to it."

  def sentence(:durable_memory_off),
    do: "Phone calls keep each call's record in Fermix's memory, which is turned off."

  def sentence(:openai_api_key_missing),
    do:
      "Phone calls need an OpenAI API key; a SpaceXAI key or a ChatGPT sign-in does not place " <>
        "a GPT-Live call."

  def sentence(:caller_number_missing),
    do: "Phone calls need the Telnyx number they call from."

  def sentence(:sip_username_missing),
    do: "Phone calls need the username of the Telnyx connection they call through."

  def sentence(:sip_password_missing),
    do: "Phone calls need the password of the Telnyx connection they call through."

  defp missing?(:not_primary, _config, inputs), do: not inputs.primary?
  defp missing?(:durable_memory_off, _config, inputs), do: not inputs.durable_memory?
  defp missing?(:openai_api_key_missing, _config, inputs), do: not inputs.openai_api_key?
  defp missing?(:caller_number_missing, config, _inputs), do: is_nil(config.caller_number)
  defp missing?(:sip_username_missing, config, _inputs), do: is_nil(config.sip_username)
  defp missing?(:sip_password_missing, _config, inputs), do: not inputs.sip_password?

  defp openai_api_key?, do: match?({:ok, _key}, Config.openai_api_key())
  defp sip_password?(config), do: match?({:ok, _password}, Config.sip_password(config))

  # A process that booted no engine (a tree-less CLI verb) is no primary.
  defp primary?, do: match?(%{role: :primary}, Role.booted())
end
