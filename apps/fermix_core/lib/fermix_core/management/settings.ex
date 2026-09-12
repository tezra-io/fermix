defmodule FermixCore.Management.Settings do
  @moduledoc """
  The `settings.*` methods: the section inventory, one section's rows, a typed
  write, and the reload that clears an external change (M34 native setup §7.3).

  Values are data and belong to the daemon; flows are presentation and belong to
  the front-end. Every label, footer, option, bound and restart flag on this
  wire is the daemon's own, so a scalar added in Elixir reaches both doors with
  no second inventory to update.

  `sections/0` is the one enumerator: the wire, the browser door and the parity
  gate all walk it, and a section reachable through `get/2` that is absent from
  it fails the contract test rather than becoming a fourth hand-written list.

  Writes go through the same tails the browser door uses, so the external-change
  refusal, the secret securing and the baseline re-record apply identically from
  either door. Nothing here re-implements a refusal.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Management.Settings.AnswerMap
  alias FermixCore.Management.Settings.Assistant
  alias FermixCore.Management.Settings.Channels
  alias FermixCore.Management.Settings.Providers
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Tools
  alias FermixCore.Management.Settings.Voice
  alias FermixCore.Meetings.Config, as: MeetingsConfig
  alias FermixCore.Readiness
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.RestartState
  alias FermixCore.Setup.Wizard

  require Logger

  @families [Providers, Assistant, Channels, Voice, Tools]

  @type section :: %{id: String.t(), pane: String.t(), title: String.t()}
  @type write_error ::
          {:invalid_params, String.t(), String.t()}
          | {:unknown_section, String.t()}
          | {:external_change, [String.t()]}
          | {:config_unreadable, String.t()}

  @doc """
  Every section this daemon can serve, ordered, with the pane it renders under.
  """
  @spec sections() :: [section()]
  def sections, do: Enum.flat_map(@families, & &1.sections())

  @doc "Whether the named section exists."
  @spec section?(String.t()) :: boolean()
  def section?(section) when is_binary(section), do: family(section) != nil

  @doc """
  One section's rows.

  Exactly one section per call, which is what keeps every result inside the
  published depth budget.
  """
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, {:unknown_section, String.t()}}
  def get(section, opts \\ []) when is_binary(section) and is_list(opts) do
    case family(section) do
      nil -> {:error, {:unknown_section, section}}
      module -> {:ok, view(section, module, snapshot(opts))}
    end
  end

  @doc """
  Applies changed keys to one section.

  Every value is checked against the row it names before anything is written, so
  a refused key never leaves half a change behind.
  """
  @spec apply(String.t(), map(), keyword()) :: {:ok, map()} | {:error, write_error()}
  def apply(section, values, opts \\ [])
      when is_binary(section) and is_map(values) and is_list(opts) do
    with {:ok, module} <- fetch_family(section),
         rows = module.rows(section, snapshot(opts)),
         {:ok, answers} <- answers(section, rows, values) do
      write(section, answers, Map.keys(values))
    end
  end

  @doc "Every row kind and number format this contract publishes."
  @spec vocabulary() :: %{kinds: [Row.kind()], formats: [atom()]}
  def vocabulary, do: %{kinds: Row.kinds(), formats: Row.formats()}

  @doc """
  Re-reads the settings file and pushes it into application environment.

  The one action behind `Reload settings from disk`, and the only member of the
  write family allowed while an external change stands. The third step is what
  clears the state: applying a snapshot writes no file and records nothing, so
  without re-recording the baseline the one offered remedy would leave every
  write refusing.
  """
  @spec reload(keyword()) :: {:ok, map()} | {:error, write_error()}
  def reload(opts \\ []) when is_list(opts) do
    case RestartState.load_persisted() do
      {:ok, persisted} -> apply_reload(persisted, opts)
      {:error, sentence} -> {:error, {:config_unreadable, sentence}}
    end
  end

  @doc "The restart state as every write result carries it."
  @spec restart() :: map()
  def restart do
    state = RestartState.restart()

    %{
      "required" => state.required,
      "reasons" => Enum.map(state.reasons, &%{"section" => &1.section, "sentence" => &1.sentence})
    }
  end

  @doc "Readiness as every write result carries it: the status and how many failures stand."
  @spec readiness() :: map()
  def readiness do
    report = Readiness.report()

    %{
      "status" => Atom.to_string(report.status),
      "failure_count" => length(report.failures)
    }
  end

  defp apply_reload(persisted, opts) do
    :ok = ConfigStore.apply_snapshot(persisted, Keyword.take(opts, [:supervised]))
    :ok = RestartState.record_persisted_baseline()

    {:ok,
     %{
       "reloaded" => true,
       "restart" => restart(),
       "readiness" => readiness(),
       "config_state" => config_state_word()
     }}
  end

  defp config_state_word do
    case RestartState.config_state() do
      :clear -> "clear"
      {:external_change, _sections} -> "external_change"
      {:config_unreadable, _sentence} -> "config_unreadable"
    end
  end

  defp view(section, module, snapshot) do
    %{id: id, title: title} = Enum.find(module.sections(), &(&1.id == section))

    %{"id" => id, "title" => title, "rows" => module.rows(section, snapshot)}
  end

  defp answers(section, rows, values) do
    Enum.reduce_while(values, {:ok, AnswerMap.context(section)}, fn {key, value}, {:ok, acc} ->
      case answer(section, rows, key, value) do
        {:ok, answer} -> {:cont, {:ok, acc ++ [answer]}}
        {:error, sentence} -> {:halt, {:error, {:invalid_params, key, sentence}}}
      end
    end)
  end

  defp answer(section, rows, key, value) do
    case Enum.find(rows, &(&1["key"] == key)) do
      nil -> {:error, "This section has no setting by that name."}
      row -> AnswerMap.answer(section, row, value)
    end
  end

  # The normalizers behind every writer raise on a value they refuse, and their
  # message is the operator-facing sentence. Rescued around the write itself and
  # nowhere wider: an exception out of this call is a statement about the value
  # that was sent, and letting it through would answer `internal_error` for what
  # is an ordinary refusal.
  defp write(section, answers, keys) do
    before = ConfigStore.current_snapshot()

    case guarded_commit(AnswerMap.writer(section), answers, field(section, keys)) do
      {:ok, _report} -> {:ok, applied(keys, before)}
      {:error, reason} -> {:error, write_error(section, reason)}
    end
  end

  defp guarded_commit(writer, answers, field) do
    commit(writer, answers)
  rescue
    exception in [ArgumentError] ->
      {:error, {:refused, field, Exception.message(exception)}}
  end

  # The field a refusal names. One key sent is the ordinary case from a pane,
  # where the operator changed one control, and naming it puts the sentence
  # under that control; a multi-key write can only honestly name the section.
  defp field(_section, [key]), do: key
  defp field(section, _keys), do: section

  defp commit(:wizard, answers) do
    state = Wizard.report().wizard
    Wizard.save_answers(state, answers)
  end

  defp commit(:meetings, answers), do: MeetingsConfig.save(answers)

  defp commit(:sandbox, answers) do
    Wizard.set_sandbox_overrides(
      sandbox_atom(answers, :sandbox_mode),
      sandbox_atom(answers, :sandbox_profile),
      Keyword.get(answers, :sandbox_env_allow)
    )
  end

  defp sandbox_atom(answers, key) do
    case Keyword.get(answers, key) do
      value when is_binary(value) -> String.to_existing_atom(value)
      nil -> nil
    end
  end

  defp write_error(section, {:external_change, _sections}), do: {:external_change, [section]}
  defp write_error(_section, {:config_unreadable, sentence}), do: {:config_unreadable, sentence}
  defp write_error(_section, {:refused, field, sentence}), do: {:invalid_params, field, sentence}

  # The residue. A writer that refuses for anything else answers with its own
  # internal term, which names files on the operator's disk, so it goes to the
  # daemon log and the published sentence stays fixed.
  defp write_error(section, reason) do
    Logger.error(
      "management settings: #{section} could not be saved: #{Redaction.format(reason)}"
    )

    {:invalid_params, section, "The change could not be saved. See the daemon log."}
  end

  defp applied(keys, before) do
    %{
      "applied" => keys,
      "restart" => restart(),
      "readiness" => readiness(),
      "side_effects" => side_effects(before, ConfigStore.current_snapshot())
    }
  end

  # Changes the operator did not type, in the daemon's own words. One rule
  # today, and it is a real one: choosing a transcription backend snaps the
  # shared model key to that backend's default, because the key is shared across
  # backends and an OpenAI-shaped model on Deepgram fails at the provider.
  defp side_effects(before, current) do
    previous = transcription_model(before)
    now = transcription_model(current)

    if previous != now and now != "" do
      ["The voice notes model changed to #{now}."]
    else
      []
    end
  end

  defp transcription_model(snapshot) do
    snapshot
    |> Map.get(:fermix_core, [])
    |> Keyword.get(:transcription, [])
    |> Keyword.get(:model, "")
    |> to_string()
  end

  defp snapshot(opts), do: Keyword.get_lazy(opts, :snapshot, &ConfigStore.current_snapshot/0)

  defp fetch_family(section) do
    case family(section) do
      nil -> {:error, {:unknown_section, section}}
      module -> {:ok, module}
    end
  end

  defp family(section), do: Enum.find(@families, & &1.owns?(section))
end
