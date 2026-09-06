defmodule FermixCore.Management.Settings.Assistant do
  @moduledoc """
  The `personalization` and `memory` sections (M34 native setup §5.7).

  Both are hot: nothing here is read once at boot, so no row is flagged for a
  restart except the skill-curation switch, which seeds a scheduler.

  `timezone` and `communication_style` are choice rows carrying the daemon's own
  suggestions, and `settings.apply` still accepts a value that is not among
  them: a client with a richer native picker sends any zone the time zone
  database knows, and the browser door's free-text field keeps working. Options
  are what a client may offer inline, never the whole value space.
  """

  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Memory.CompactionConfig
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.SkillCuration.Delivery, as: SkillCurationDelivery

  # Suggestions, ordered west to east, each rendered with its current offset.
  # A client that can enumerate the whole database sends its own value; this is
  # the inline list, bounded well under the published option ceiling.
  @timezone_suggestions ~w(
    Pacific/Honolulu America/Anchorage America/Los_Angeles America/Denver
    America/Chicago America/New_York America/Sao_Paulo Europe/London
    Europe/Berlin Europe/Madrid Europe/Athens Africa/Lagos Africa/Johannesburg
    Asia/Dubai Asia/Kolkata Asia/Singapore Asia/Shanghai Asia/Tokyo
    Australia/Sydney Pacific/Auckland UTC
  )

  @style_suggestions [
    {"Answer in as few words as the question allows.", "Concise"},
    {"Answer in a few sentences, and go longer when the question needs it.", "Balanced"},
    {"Explain your reasoning and cover the edges.", "Detailed"}
  ]

  @sections [
    %{id: "personalization", pane: "personality", title: "About you"},
    %{id: "memory", pane: "memory", title: "Memory"}
  ]

  @doc "Both sections, in publication order."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: @sections

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: Enum.any?(@sections, &(&1.id == section))

  @doc "The rows of one owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("personalization", snapshot) do
    block = Source.core(snapshot, :personalization)
    hot = Row.restart?(:personalization)

    [
      Row.new("user_name", :text, "Your name",
        value: Source.string(block, :user_name),
        restart: hot
      ),
      timezone_row(block, hot),
      style_row(block, hot),
      Row.new("bot_name", :text, "Call the assistant",
        value: Source.string(Source.core(snapshot, :agent), :name),
        restart: hot
      ),
      skill_curation_row(snapshot)
    ]
  end

  def rows("memory", snapshot) do
    compaction = Source.core(snapshot, :compaction)
    memory = Source.core(snapshot, :memory)

    [
      Row.new("compaction_threshold", :number, "Compact a conversation at",
        footer: "How full the context window gets before older turns are summarized.",
        value: Source.number(compaction, :threshold, CompactionConfig.threshold([])),
        min: 0.1,
        max: 1.0,
        step: 0.01,
        format: :percent,
        restart: Row.restart?(:compaction)
      ),
      Row.new("review_interval_hours", :number, "Review memory every",
        footer: "0 turns background review off.",
        value:
          Source.number(memory, :review_interval_hours, MemoryConfig.review_interval_hours()),
        min: 0,
        step: 1,
        unit: "hours",
        format: :hours,
        restart: Row.restart?(:memory)
      )
    ]
  end

  defp timezone_row(block, restart) do
    value = Source.string(block, :timezone)
    values = Enum.uniq(offered(value, @timezone_suggestions))

    Row.new("timezone", :choice, "Time zone",
      value: value,
      options: Enum.map(values, &Row.option(&1, zone_label(&1), hint: zone_hint(&1))),
      suggestions: true,
      restart: restart
    )
  end

  defp style_row(block, restart) do
    value = Source.string(block, :communication_style)
    suggested = Enum.map(@style_suggestions, fn {sentence, _label} -> sentence end)

    options =
      Enum.map(offered(value, suggested), fn sentence ->
        Row.option(sentence, style_label(sentence))
      end)

    Row.new("communication_style", :choice, "Style",
      value: value,
      options: options,
      suggestions: true,
      restart: restart
    )
  end

  # A configured value that is not one of the suggestions still has to be
  # selectable, or opening the pane would offer every value except the one in
  # force.
  defp offered("", suggestions), do: suggestions
  defp offered(value, suggestions), do: Enum.uniq([value | suggestions])

  defp style_label(sentence) do
    case List.keyfind(@style_suggestions, sentence, 0) do
      {^sentence, label} -> label
      nil -> "Your own words"
    end
  end

  defp zone_label("UTC"), do: "UTC"

  defp zone_label(zone) do
    zone |> String.split("/") |> List.last() |> String.replace("_", " ")
  end

  # The offset is a hint, and a zone the database cannot resolve simply has
  # none: a suggestion list is not the place to fail a whole pane.
  defp zone_hint(zone) do
    case DateTime.now(zone) do
      {:ok, now} -> "GMT#{offset_words(now.utc_offset + now.std_offset)}"
      {:error, _reason} -> nil
    end
  end

  defp offset_words(0), do: "+0"

  defp offset_words(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    minutes = div(abs(seconds), 60)

    case rem(minutes, 60) do
      0 -> "#{sign}#{div(minutes, 60)}"
      remainder -> "#{sign}#{div(minutes, 60)}:#{String.pad_leading("#{remainder}", 2, "0")}"
    end
  end

  # The footer names where a proposal would arrive, resolved once by the one
  # owner-inbox resolver, so the pane never claims a destination that does not
  # exist.
  defp skill_curation_row(snapshot) do
    Row.new(
      "skill_curation_enabled",
      :toggle,
      "Suggest new skills from tasks you repeat",
      footer: skill_curation_footer(),
      value: Source.boolean(Source.core(snapshot, :skill_curation), :enabled, true),
      restart: Row.restart?(:skill_curation)
    )
  end

  defp skill_curation_footer do
    case SkillCurationDelivery.resolve_target() do
      {:ok, target} -> "Suggestions arrive in #{target.platform}."
      :no_delivery_target -> "Suggestions wait until a channel owner is configured."
    end
  end
end
