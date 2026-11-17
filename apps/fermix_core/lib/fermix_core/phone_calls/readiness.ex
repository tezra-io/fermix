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
  whether durable memory is on (`Memory.Config.enabled?/0`: a call's record
  lives in `memory.db`), and whether the network proxy would carry the call's
  live control connection, which cannot tunnel (`OpenAILive.control_route/1`,
  the test the call's create makes before it sends), and whether the engine
  has the backend a call's turns run on (`PhoneCalls.Delegate.configured/0`,
  the module the composition root hands every call's worker: without one a
  call could neither press a key nor end through a backend turn). Each can be
  handed in instead, for a test.

  Readiness says nothing about a call in progress or an unresolved one; the
  call's own state does. A SpaceXAI key never makes phone calls ready.

  A stored OpenAI key that no request could carry (a key saved with a trailing
  line break, say) is its own reason, decided by the transport's one rule
  (`OpenAILive.sendable_api_key?/1`), so it is found before any attempt rather
  than when every call ends unsent. A missing key is only missing. The trunk's
  username and password need no such reason: `Config` refuses, on every read
  and write, any value the transport could not send.
  """

  alias FermixCore.Home.Role
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Delegate
  alias FermixCore.PhoneCalls.OpenAILive

  @reasons [
    :not_primary,
    :durable_memory_off,
    :openai_api_key_missing,
    :openai_api_key_unsendable,
    :caller_number_missing,
    :sip_username_missing,
    :sip_password_missing,
    :egress_proxy_unsupported,
    :call_backend_missing
  ]

  @type reason ::
          :not_primary
          | :durable_memory_off
          | :openai_api_key_missing
          | :openai_api_key_unsendable
          | :caller_number_missing
          | :sip_username_missing
          | :sip_password_missing
          | :egress_proxy_unsupported
          | :call_backend_missing

  @type status :: :disabled | :ready | {:needs_setup, [reason(), ...]}

  @type inputs :: %{
          required(:config) => Config.t(),
          required(:openai_api_key?) => boolean(),
          required(:openai_api_key_unsendable?) => boolean(),
          required(:sip_password?) => boolean(),
          required(:primary?) => boolean(),
          required(:durable_memory?) => boolean(),
          required(:control_route?) => boolean(),
          required(:call_backend?) => boolean()
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
          openai_api_key_unsendable?: unsendable?,
          sip_password?: password?,
          primary?: primary?,
          durable_memory?: memory?,
          control_route?: route?,
          call_backend?: backend?
        } = inputs
      )
      when is_boolean(key?) and is_boolean(unsendable?) and is_boolean(password?) and
             is_boolean(primary?) and
             is_boolean(memory?) and is_boolean(route?) and is_boolean(backend?) do
    missing =
      Enum.filter(@reasons, fn reason -> missing?(reason, config, inputs) end)

    if missing == [], do: :ready, else: {:needs_setup, missing}
  end

  @doc """
  Readiness of the running engine. Any input `decide/1` takes may be given in
  `opts` (`:config`, `:openai_api_key?`, `:openai_api_key_unsendable?`,
  `:sip_password?`, `:primary?`,
  `:durable_memory?`, `:control_route?`, `:call_backend?`); each one absent is read from its
  source, the control route over `opts[:egress]` (default the active one).
  """
  @spec current(keyword()) :: status()
  def current(opts \\ []) when is_list(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.get/0)

    decide(%{
      config: config,
      openai_api_key?: Keyword.get_lazy(opts, :openai_api_key?, &openai_api_key?/0),
      openai_api_key_unsendable?:
        Keyword.get_lazy(opts, :openai_api_key_unsendable?, &openai_api_key_unsendable?/0),
      sip_password?: Keyword.get_lazy(opts, :sip_password?, fn -> sip_password?(config) end),
      primary?: Keyword.get_lazy(opts, :primary?, &primary?/0),
      durable_memory?: Keyword.get_lazy(opts, :durable_memory?, &MemoryConfig.enabled?/0),
      control_route?:
        Keyword.get_lazy(opts, :control_route?, fn ->
          control_route?(Keyword.take(opts, [:egress]))
        end),
      call_backend?: Keyword.get_lazy(opts, :call_backend?, &call_backend?/0)
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

  def sentence(:openai_api_key_unsendable),
    do:
      "The stored OpenAI API key cannot be sent as it is, because it holds a space, a line " <>
        "break or another character a request cannot carry; enter the key again."

  def sentence(:caller_number_missing),
    do: "Phone calls need the Telnyx number they call from."

  def sentence(:sip_username_missing),
    do: "Phone calls need the username of the Telnyx connection they call through."

  def sentence(:sip_password_missing),
    do: "Phone calls need the password of the Telnyx connection they call through."

  def sentence(:egress_proxy_unsupported),
    do:
      "Phone calls keep a live connection to OpenAI that the network proxy cannot carry; " <>
        "let OpenAI's API bypass the proxy to place calls."

  def sentence(:call_backend_missing),
    do:
      "Phone calls need Fermix's backend for calls, which this engine was started " <>
        "without, so a call could neither press a key nor hang up."

  defp missing?(:not_primary, _config, inputs), do: not inputs.primary?
  defp missing?(:durable_memory_off, _config, inputs), do: not inputs.durable_memory?
  defp missing?(:openai_api_key_missing, _config, inputs), do: not inputs.openai_api_key?

  defp missing?(:openai_api_key_unsendable, _config, inputs),
    do: inputs.openai_api_key? and inputs.openai_api_key_unsendable?

  defp missing?(:caller_number_missing, config, _inputs), do: is_nil(config.caller_number)
  defp missing?(:sip_username_missing, config, _inputs), do: is_nil(config.sip_username)
  defp missing?(:sip_password_missing, _config, inputs), do: not inputs.sip_password?
  defp missing?(:egress_proxy_unsupported, _config, inputs), do: not inputs.control_route?
  defp missing?(:call_backend_missing, _config, inputs), do: not inputs.call_backend?

  defp openai_api_key?, do: match?({:ok, _key}, Config.openai_api_key())

  # A stored key the transport would refuse; no key is not this reason.
  defp openai_api_key_unsendable? do
    case Config.openai_api_key() do
      {:ok, key} -> not OpenAILive.sendable_api_key?(key)
      {:error, :missing_openai_api_key} -> false
    end
  end

  defp sip_password?(config), do: match?({:ok, _password}, Config.sip_password(config))

  # Only the proxy's refusal is this reason: an origin the build refuses is
  # the create's own error, in its own words.
  defp control_route?(opts) do
    not match?(
      {:error, {:not_sent, :proxy_unsupported_transport}},
      OpenAILive.control_route(opts)
    )
  end

  # The backend a call's turns run on, as the composition root wires it.
  defp call_backend?, do: match?({:ok, _module}, Delegate.configured())

  # A process that booted no engine (a tree-less CLI verb) is no primary.
  defp primary?, do: match?(%{role: :primary}, Role.booted())
end
