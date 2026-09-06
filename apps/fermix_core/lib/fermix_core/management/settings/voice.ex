defmodule FermixCore.Management.Settings.Voice do
  @moduledoc """
  The `realtime`, `transcription` and `meetings` sections (M34 native setup
  §5.3, §5.4).

  The shared OpenAI key is named on the voice section rather than hidden: it is
  the same slot the OpenAI provider uses, and a pane that showed a second,
  unrelated-looking key row is what made operators store it twice.
  """

  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Meetings.Config, as: MeetingsConfig
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Transcription.Registry, as: TranscriptionRegistry

  @sections [
    %{id: "realtime", pane: "voice", title: "Voice"},
    %{id: "transcription", pane: "voice", title: "Voice notes"},
    %{id: "meetings", pane: "meetings", title: "Meeting notetaker"}
  ]

  @backend_labels %{
    "openai" => "OpenAI",
    "xai" => "SpaceXAI",
    "deepgram" => "Deepgram",
    "local" => "On this Mac"
  }

  # The key slot each transcription backend reads. `local` runs on this Mac and
  # authenticates with nothing, so it has no row rather than an empty one.
  @backend_secrets %{
    "openai" => :transcription_openai_api_key,
    "xai" => :transcription_xai_api_key,
    "deepgram" => :deepgram_api_key
  }

  @effort_labels %{
    "minimal" => "Minimal",
    "low" => "Low",
    "medium" => "Medium",
    "high" => "High",
    "xhigh" => "Extra high"
  }

  @doc "Every section this module owns, in publication order."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: @sections

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: Enum.any?(@sections, &(&1.id == section))

  @doc "The rows of one owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("realtime", snapshot) do
    config = RealtimeConfig.normalize(Source.core(snapshot, :realtime))
    restart = Row.restart?(:realtime)

    realtime_switch_rows(config, restart) ++
      realtime_key_row(snapshot) ++ realtime_budget_rows(config, restart)
  end

  def rows("transcription", snapshot) do
    block = Source.core(snapshot, :transcription)
    backend = Source.string(block, :backend, "openai")
    restart = Row.restart?(:transcription)

    transcription_choice_rows(block, backend, restart) ++
      transcription_key_row(snapshot, backend, restart)
  end

  def rows("meetings", snapshot) do
    block = Source.core(snapshot, :meetings)
    restart = Row.restart?(:meetings)

    meetings_bot_rows(block, restart) ++
      meetings_zoom_rows(block, snapshot, restart) ++ [meetings_backend_row(block, restart)]
  end

  defp realtime_switch_rows(config, restart) do
    [
      Row.new("realtime_enabled", :toggle, "Talk to Fermix",
        footer: "Lets the companion talk with you using OpenAI Realtime.",
        value: config.enabled?,
        restart: restart
      ),
      Row.new("realtime_model", :choice, "Model",
        value: config.model,
        options: Enum.map(RealtimeConfig.valid_models(), &Row.option(&1, &1)),
        restart: restart
      ),
      Row.new("realtime_voice", :choice, "Voice",
        value: config.voice,
        options: Enum.map(RealtimeConfig.valid_voices(), &Row.option(&1, String.capitalize(&1))),
        restart: restart
      ),
      Row.new("realtime_reasoning_effort", :choice, "Reasoning effort",
        value: config.reasoning_effort,
        options: Enum.map(RealtimeConfig.valid_reasoning_efforts(), &effort_option/1),
        restart: restart
      )
    ]
  end

  # Named, not hidden: this is the OpenAI provider's own slot, and `secret.set`
  # writes it under that id from either pane.
  defp realtime_key_row(snapshot) do
    [
      Row.new("openai_api_key", :secret, "OpenAI key",
        footer: "The same key the OpenAI provider uses.",
        present: Source.secret_present?(snapshot, :openai_api_key),
        restart: Row.restart?(:providers)
      )
    ]
  end

  defp realtime_budget_rows(config, restart) do
    [
      Row.new("realtime_max_session_minutes", :number, "End a conversation after",
        value: config.max_session_minutes,
        min: 1,
        max: 240,
        step: 1,
        unit: "minutes",
        format: :minutes,
        restart: restart
      ),
      Row.new("realtime_max_cost_cents", :number, "Stop a conversation at",
        value: config.max_estimated_cost_cents_per_session,
        min: 1,
        step: 1,
        format: :currency_cents,
        restart: restart
      ),
      Row.new("realtime_persist_transcripts", :toggle, "Keep transcripts",
        value: config.persist_transcripts?,
        restart: restart
      )
    ]
  end

  defp transcription_choice_rows(block, backend, restart) do
    [
      Row.new("transcription_backend", :choice, "Transcribe with",
        value: backend,
        options: Enum.map(backend_names(), &Row.option(&1, backend_label(&1))),
        restart: restart
      ),
      Row.new("transcription_model", :choice, "Model",
        value: Source.string(block, :model),
        options: model_options(backend),
        suggestions: true,
        restart: restart
      )
    ]
  end

  # One key row, for the backend in force. Publishing every backend's slot would
  # ask an operator to store three keys to use one.
  defp transcription_key_row(snapshot, backend, restart) do
    case Map.fetch(@backend_secrets, backend) do
      {:ok, key} ->
        [
          Row.new(Atom.to_string(key), :secret, transcription_key_label(backend),
            footer: transcription_key_footer(backend),
            present: Source.secret_present?(snapshot, key),
            restart: restart
          )
        ]

      :error ->
        []
    end
  end

  defp transcription_key_label("deepgram"), do: "Deepgram key"
  defp transcription_key_label(_backend), do: "Transcription key"

  defp transcription_key_footer("deepgram"), do: nil

  defp transcription_key_footer(backend),
    do: "Overrides the #{backend_label(backend)} key for voice notes."

  defp meetings_bot_rows(block, restart) do
    [
      Row.new("meetings_enabled", :toggle, "Meeting notetaker",
        footer:
          "Enable meeting notes for Google Meet and Zoom. " <>
            "Google Meet needs the notetaker and browser installed; Zoom uses its RTMS credentials.",
        value: Source.boolean(block, :enabled, false),
        restart: restart
      ),
      Row.new("meetings_bot_name", :text, "Bot name",
        value: Source.string(block, :bot_name, MeetingsConfig.default_bot_name()),
        restart: restart
      ),
      Row.new("meetings_announce", :toggle, "Announce when joining",
        value: Source.boolean(block, :announce, true),
        restart: restart
      ),
      Row.new("meetings_announce_message", :text, "Announcement",
        footer: "Blank uses the built-in line.",
        value: Source.string(block, :announce_message),
        restart: restart
      )
    ]
  end

  defp meetings_zoom_rows(block, snapshot, restart) do
    [
      Row.new("meetings_zoom_account_id", :text, "Zoom account ID",
        value: Source.string(block, :zoom_account_id),
        restart: restart
      ),
      Row.new("meetings_zoom_client_id", :text, "Zoom client ID",
        value: Source.string(block, :zoom_client_id),
        restart: restart
      ),
      Row.new("meetings_zoom_client_secret", :secret, "Zoom client secret",
        present: Source.secret_present?(snapshot, :meetings_zoom_client_secret),
        restart: restart
      ),
      Row.new("meetings_zoom_ws_subscription_id", :text, "Zoom subscription ID",
        value: Source.string(block, :zoom_ws_subscription_id),
        restart: restart
      )
    ]
  end

  defp meetings_backend_row(block, restart) do
    options = [
      Row.option("", "Same as voice notes")
      | Enum.map(backend_names(), &Row.option(&1, backend_label(&1)))
    ]

    Row.new("meetings_transcription_backend", :choice, "Transcribe with",
      value: Source.string(block, :transcription_backend),
      options: options,
      restart: restart
    )
  end

  defp effort_option(level), do: Row.option(level, Map.fetch!(@effort_labels, level))

  defp backend_names do
    Enum.map(TranscriptionRegistry.backends(), fn {name, _module} -> Atom.to_string(name) end)
  end

  defp backend_label(backend), do: Map.fetch!(@backend_labels, backend)

  # A modelless backend publishes no options, which is the truthful answer: the
  # endpoint runs one fixed model and takes no model parameter. An unknown
  # backend name has none either, and the choice row above still shows it as the
  # value in force.
  defp model_options(backend) do
    case TranscriptionRegistry.supported_models(backend) do
      {:ok, models} -> Enum.map(models, &Row.option(&1, &1))
      {:error, _reason} -> []
    end
  end
end
