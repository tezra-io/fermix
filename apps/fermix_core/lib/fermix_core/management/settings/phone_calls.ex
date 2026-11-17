defmodule FermixCore.Management.Settings.PhoneCalls do
  @moduledoc """
  The `phone_calls` section, Settings, Voice, Phone calls (M94 §12): the
  owner's five settings of `[fermix_core.phone_calls]` (decision D5) and two
  facts the engine publishes beside them.

  The rows: whether Fermix may place calls; the summary of where phone calls
  stand (`Management.PhoneCalls.summary/1`, read-only); the engine that calls,
  GPT-Live, a fact and not a picker; the voice the people called hear, from
  the engine's one catalog (`PhoneCalls.Config.voices/0`); the owner's caller
  number; the Telnyx connection's username; its password, a secret row bound
  to `:phone_calls_sip_password`; and the OpenAI key, a second row for the
  `openai_api_key` secret the OpenAI provider and Talk to Fermix already use,
  never a second credential, shown whichever provider Talk to Fermix uses. The
  trunk address, the model, the limits and the retention are constants of the
  engine (`PhoneCalls.CarrierProfile`, `PhoneCalls.Limits`) and no rows.

  The section is the home's, not a computer's: Voice is no machine section, so
  after a move every app shows the server's. It is its own: no row here reads
  or writes `[fermix_core.realtime]`, and a write here never touches it.

  No row asks for a restart (`[fermix_core.phone_calls]` is not boot-bound),
  except the OpenAI key, whose write is the OpenAI provider's and carries that
  provider section's restart rule wherever its row is shown. The switch is
  live: `Management.Settings` applies it once the write lands
  (`Management.PhoneCalls.apply_enabled/2`), in the same operation.

  `save/1` is the section's one writer. A value is checked with
  `PhoneCalls.Config.validate/1`, whose reasons are said here in the owner's
  words, before anything is written, then the section is committed through
  the wizard's shared write tail, as every section's write is.
  """

  alias FermixCore.Management.PhoneCalls, as: PhoneCallFacts
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Limits
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

  @section %{id: "phone_calls", pane: "voice", title: "Phone calls"}
  @prefix "phone_calls_"
  # An invented number in the 555-01XX range, which NANPA keeps for fiction.
  @example_number "+12125550142"

  @refusals %{
    caller_number: %{
      not_e164: "Enter your Telnyx number in international form: a plus sign, then its digits.",
      not_nanp_number:
        "That is not a number Fermix can call from. Enter the US number you " <>
          "bought from Telnyx.",
      destination_not_us:
        "Phone calls come from a US number. Enter the US number you bought " <>
          "from Telnyx.",
      emergency_or_special_number:
        "That is an emergency, service, toll-free or premium " <>
          "number. Enter the US number you bought from Telnyx."
    },
    sip_username: %{
      too_long:
        "That username is longer than a connection username can be. Copy it again " <>
          "from your Telnyx connection.",
      control_characters:
        "A connection username is one line. Copy it again from your " <>
          "Telnyx connection."
    }
  }
  @plain_text_sentence "This setting takes plain text."
  @voice_sentence "Choose one of the voices listed."
  @switch_sentence "This switch is on or off."

  # What the owner accepts by turning phone calls on (M94 §12): how long a call
  # can run if Fermix loses hold of it, and what is kept of it and for how long.
  defp enabled_footer do
    hours = div(Limits.provider_connected_limit_ms(), 3_600_000)

    "Lets Fermix call a business or your own phone when you ask, from your Telnyx number. " <>
      "If Fermix loses hold of a call, it can run until OpenAI's own limit of #{hours} " <>
      "hours, and your Telnyx connection's daily spend limit bounds what it costs. Fermix " <>
      "keeps a call's outcome and brief for #{Limits.outcome_retention_days()} days and short " <>
      "excerpts of what was said for #{Limits.excerpt_retention_days()} days, records no " <>
      "audio, and a report sent to a chat stays in that chat."
  end

  @doc "The one section this module owns."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: [@section]

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: section == @section.id

  @doc """
  The rows of the owned section. `opts[:phone_calls]` reaches
  `Management.PhoneCalls.summary/1` (its ledger, call manager and clock), for
  a test; the settings methods pass none.
  """
  @spec rows(String.t(), Source.snapshot(), keyword()) :: [Row.t()]
  def rows(section, snapshot, opts \\ [])

  def rows("phone_calls", snapshot, opts) when is_map(snapshot) and is_list(opts) do
    config = Config.normalize(Source.core(snapshot, :phone_calls))
    restart = Row.restart?(:phone_calls)

    [
      Row.new("phone_calls_enabled", :toggle, "Phone calls",
        footer: enabled_footer(),
        value: config.enabled,
        restart: restart
      ),
      status_row(config, Keyword.get(opts, :phone_calls, []), restart),
      Row.new("phone_calls_engine", :text, "Calls with",
        footer:
          "GPT-Live speaks on every call, through your Telnyx connection. Talk to " <>
            "Fermix keeps its own model.",
        value: PhoneCallFacts.engine_label(),
        read_only: true,
        restart: restart
      )
    ] ++ setup_rows(config, snapshot, restart)
  end

  defp setup_rows(config, snapshot, restart) do
    [
      Row.new("phone_calls_voice", :choice, "Voice",
        footer: "The voice the people Fermix calls hear.",
        value: config.voice,
        options: Enum.map(Config.voices(), &Row.option(&1, String.capitalize(&1))),
        restart: restart
      ),
      Row.new("phone_calls_caller_number", :text, "Caller number",
        footer: "The number you bought from Telnyx. Calls come from it.",
        example: @example_number,
        value: config.caller_number || "",
        restart: restart
      ),
      Row.new("phone_calls_sip_username", :text, "Connection username",
        footer: "Telnyx makes it for your credential connection. It is not your Telnyx login.",
        value: config.sip_username || "",
        restart: restart
      ),
      Row.new("phone_calls_sip_password", :secret, "Connection password",
        footer:
          "Telnyx makes it with the username. Fermix hands it to OpenAI only to place " <>
            "your calls through Telnyx.",
        present: Source.secret_present?(snapshot, :phone_calls_sip_password),
        restart: restart
      ),
      Row.new("openai_api_key", :secret, "OpenAI key",
        footer:
          "The same key the OpenAI provider uses. Phone calls need it even when Talk to " <>
            "Fermix uses Grok.",
        present: Source.secret_present?(snapshot, :openai_api_key),
        restart: Row.restart?(:providers)
      )
    ]
  end

  # Read from the same snapshot as the key rows beside it, so the summary and
  # the rows never disagree about which credential is missing.
  # The summary `phone_calls.status` publishes, of the section's own config:
  # whether the credentials are stored and can be sent is read where
  # `PhoneCalls.Readiness.current/1` reads it, the one place both come from.
  defp status_row(config, phone_opts, restart) do
    {label, sentence} = phone_opts |> Keyword.put(:config, config) |> summary()

    Row.new("phone_calls_status", :text, "Status",
      footer: sentence,
      value: label,
      read_only: true,
      restart: restart
    )
  end

  defp summary(opts) do
    case PhoneCallFacts.summary(opts) do
      {:ok, %{"label" => label, "sentence" => sentence}} -> {label, sentence}
      {:error, {:unavailable, _capability, sentence}} -> {"Unknown", sentence}
    end
  end

  @doc """
  Writes one `settings.apply` of the section. `answers` are the section's own
  keys (`enabled`, `voice`, `caller_number`, `sip_username`); a value the
  section refuses answers `{:invalid_value, row, sentence}` and writes nothing.
  """
  @spec save(keyword()) ::
          {:ok, map()} | {:error, {:invalid_value, String.t(), String.t()} | term()}
  def save(answers) when is_list(answers) do
    snapshot = ConfigStore.current_snapshot()
    core = Map.get(snapshot, :fermix_core, [])
    block = core |> Keyword.get(:phone_calls, []) |> Keyword.merge(answers)

    with :ok <- check(block) do
      snapshot
      |> Map.put(:fermix_core, Keyword.put(core, :phone_calls, block))
      |> Wizard.commit_snapshot()
    end
  end

  defp check(block) do
    case Config.validate(block) do
      {:ok, _config} ->
        :ok

      {:error, [{key, reason} | _rest]} ->
        {:error, {:invalid_value, row_key(key), refusal(key, reason)}}
    end
  end

  defp row_key(key), do: @prefix <> to_string(key)

  # Each reason `Config.validate/1` can give, in the owner's words. A reason
  # with no sentence here raises rather than reaching the owner as a code.
  defp refusal(_key, reason) when reason in [:not_a_string, :invalid_utf8],
    do: @plain_text_sentence

  defp refusal(:voice, :unknown_voice), do: @voice_sentence
  defp refusal(:enabled, :not_boolean), do: @switch_sentence
  defp refusal(:sip_password, reason), do: PhoneCallFacts.password_sentence(reason)
  defp refusal(key, reason), do: @refusals |> Map.fetch!(key) |> Map.fetch!(reason)

  @doc "Every refusal sentence the section's write can answer, for the copy gate."
  @spec refusal_sentences() :: [String.t(), ...]
  def refusal_sentences do
    [@plain_text_sentence, @voice_sentence, @switch_sentence] ++
      Enum.flat_map(@refusals, fn {_key, by_reason} -> Map.values(by_reason) end)
  end
end
