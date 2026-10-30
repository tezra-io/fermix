defmodule FermixCore.Cues.Card do
  @moduledoc """
  The card a chat shows when a watcher asks the owner first
  (M60_WATCHER_CODING_RUNS.md §6): a follow-up waiting to run (§6.1), the
  prompt that lets an automatic follow-up run on its own (§3.4), and a
  mandate's proposal (§6.3). One layout, made for a phone: a few short lines
  the owner decides from, everything in full behind a Details part, and two
  answers. No JSON, no model frames, no ids.

  Pure. A card is `lines` (what a chat shows at once, the question first),
  `detail` (the expandable part, its first line its label), `actions` (the
  two buttons' words) and `reply` (the line a chat without buttons ends
  with). `spec/2` makes it the approval spec a channel delivers
  (`FermixCore.Reply.approval_spec/0`): Telegram draws the lines, the detail
  as an expandable quote and the two buttons; every other chat gets `text`,
  the lines, the detail and the reply line.

  Outside text (the item, the filter's reason, a mandate's arguments) is cut
  on the visible lines and kept whole in the detail. A mandate's arguments
  decide what runs, so every one is shown, and a proposal too long to show
  whole is refused by `Cues.Proposals`, never cut. A follow-up's run is handed
  nothing of the item, so its detail keeps the item's text up to what fits.
  Times are the owner's (`FermixCore.Clock`).

  Opts: `:now`, `:chat` (`%{platform, chat_id}`, where the card goes, so a
  follow-up that reports there "reports here"), and the clock's
  `:personalization`.
  """

  alias FermixCore.Clock
  alias FermixCore.Cues.ProposalView

  @max_chars 3_500
  @quote_chars 100
  @reason_chars 100
  @instructions_chars 120
  @argument_chars 80
  @run_actions %{confirm: "▶ Run", deny: "Skip"}
  @approval_actions %{confirm: "✅ Approve", deny: "❌ Keep asking"}
  @run_reply "Reply /confirm to run or /deny to skip."
  @approval_reply "Reply /confirm to approve or /deny to keep asking."
  @platform_names %{
    "telegram" => "Telegram",
    "signal" => "Signal",
    "whatsapp" => "WhatsApp",
    "imessage" => "iMessage",
    "slack" => "Slack",
    "discord" => "Discord",
    "companion" => "the Fermix app",
    "mobile" => "your phone"
  }

  @typedoc "A card's two answers, in a chat's words."
  @type actions :: %{confirm: String.t(), deny: String.t()}

  @typedoc "A compact card, ready for `spec/2`."
  @type t :: %{
          kind: :follow_up | :mandate,
          lines: [String.t()],
          detail: String.t(),
          actions: actions(),
          reply: String.t()
        }

  @doc "The longest card a chat is sent, in characters."
  @spec max_chars() :: pos_integer()
  def max_chars, do: @max_chars

  @doc """
  The card the follow-up sender is handed (`:cue_follow_up_sender`): a
  follow-up's card from `Cues.FollowUps.card/2`, or an approval's prompt from
  `Cues.FollowUpApprovals.card/2`.
  """
  @spec of(map(), keyword()) :: t()
  def of(%{trigger_id: _id} = card, opts), do: follow_up(card, opts)
  def of(%{shown_digest: _digest} = card, opts), do: approval(card, opts)

  @doc """
  The card of a follow-up waiting to run (§6.1), from `Cues.FollowUps.card/2`.
  The item's text in the detail is cut to what fits: the run never gets it.
  """
  @spec follow_up(map(), keyword()) :: t()
  def follow_up(%{follow_up: follow_up, outside: outside} = card, opts) when is_list(opts) do
    lines =
      [
        "Run #{quoted(follow_up_name(card))}?",
        quote_line(outside, opts),
        reason_line(outside.reason),
        "It will: " <> one_line(follow_up.instructions, @instructions_chars),
        "Expires #{time(card.expires_at, opts)} · reports #{where(follow_up.delivery, opts)}"
      ]
      |> Enum.reject(&is_nil/1)

    fixed = [
      "Watcher: #{card.watcher.name || "(removed)"}",
      "It will, in full:",
      follow_up.instructions || "",
      "Uses: " <> Enum.join(follow_up.tools, ", "),
      "Reports to: " <> reports_to(follow_up.delivery, opts)
    ]

    # The item's text takes the room the rest leaves: the run never gets it.
    without_text = follow_up_card(lines, item_lines(%{outside | text: ""}), fixed)
    room = max(@max_chars - String.length(text(without_text)), 2)
    item = %{outside | text: ProposalView.bounded(outside.text || "", room)}
    follow_up_card(lines, item_lines(item), fixed)
  end

  defp follow_up_card(lines, item, fixed) do
    detail = Enum.join(["Details" | item] ++ fixed, "\n")
    card(:follow_up, lines, detail, @run_actions, @run_reply)
  end

  @doc """
  The prompt that lets an automatic follow-up run on its own (§3.4), from
  `Cues.FollowUpApprovals.card/2`: what it runs, how often at most, and in
  the detail everything its approval is bound to (§5).
  """
  @spec approval(map(), keyword()) :: t()
  def approval(%{watcher_name: watcher} = card, opts) when is_list(opts) do
    name = quoted(card.job_name || card.job_id || "the follow-up")
    tools = Enum.join(card.allowed_tools, ", ")

    lines = [
      "Automatic follow-up for #{watcher}: whenever an item passes, run #{name} " <>
        "(#{one_line(card.task_prompt, @instructions_chars)}), with no card.",
      "That is a run with #{tools} each time, at most #{card.daily_cap} a day " <>
        "(the watcher's daily cap).",
      "Expires #{time(card.expires_at, opts)}"
    ]

    detail =
      Enum.join(
        [
          "Details",
          "It will, in full:",
          card.task_prompt || "",
          "Uses: " <> tools,
          "Reports to: " <>
            reports_to(%{mode: card.delivery_mode, target: card.delivery_target}, opts),
          "Set off by: " <> set_off_by(card)
        ],
        "\n"
      )

    card(:follow_up, lines, detail, @approval_actions, @approval_reply)
  end

  @doc """
  The card of a mandate's proposal (§6.3): the tool and the watcher, the item,
  the filter's reason and every argument as `name: value`, cut on its line and
  whole in the detail with the whole item. `proposal` carries `tool`, `args`,
  `mandate` (its name), `task` (the job's name), `cue` (the run's cue context),
  `snapshot` and `expires_at`.
  """
  @spec mandate(map(), keyword()) :: t()
  def mandate(%{tool: tool, args: args} = proposal, opts) when is_map(args) and is_list(opts) do
    outside = mandate_outside(proposal)
    watcher = Map.get(proposal.cue, :watcher_name) || "a watcher"

    lines =
      ["Run #{tool} for #{watcher}?", quote_line(outside, opts), reason_line(outside.reason)] ++
        Enum.map(arguments(args), fn {name, value} ->
          name <> ": " <> one_line(value, @argument_chars)
        end) ++
        ["Expires #{time(proposal.expires_at, opts)}"]

    detail =
      Enum.join(
        ["Every argument, whole, and the whole item"] ++
          Enum.map(arguments(args), fn {name, value} -> name <> ": " <> value end) ++
          item_lines(outside) ++
          ["Mandate: #{proposal.mandate} · task: #{proposal.task}"],
        "\n"
      )

    card(:mandate, Enum.reject(lines, &is_nil/1), detail, @run_actions, @run_reply)
  end

  @doc """
  The approval spec a channel delivers for `card` with confirmation `token`:
  `text` is the whole card for a chat without buttons.
  """
  @spec spec(t(), String.t()) :: FermixCore.Reply.approval_spec()
  def spec(%{kind: kind, lines: lines, detail: detail, actions: actions} = card, token)
      when is_binary(token) do
    %{
      kind: kind,
      text: text(card),
      token: token,
      lines: lines,
      detail: detail,
      actions: actions
    }
  end

  @doc "The whole card as one plain message: the lines, the detail, the reply line."
  @spec text(t()) :: String.t()
  def text(%{lines: lines, detail: detail, reply: reply}),
    do: Enum.join(lines, "\n") <> "\n\n" <> detail <> "\n\n" <> reply

  @doc """
  The one line a follow-up's card becomes once the owner said yes (§3.3): it
  is starting, naming the item so the run's report can be matched to it. Its
  turn may still refuse it, and `not_started/1` then says why.
  """
  @spec starting(map(), keyword()) :: String.t()
  def starting(%{outside: outside} = card, opts) do
    "Starting #{quoted(follow_up_name(card))} for #{post(outside)} · " <>
      Clock.stated_time(now(opts), opts)
  end

  @doc """
  What the owner is told when a follow-up they confirmed did not start: the
  watcher, the follow-up and the item its card named, and Fermix's sentence
  of why, the refused trigger's `reason`.
  """
  @spec not_started(map()) :: String.t()
  def not_started(%{reason: reason, outside: outside} = card) when is_binary(reason) do
    "Watcher #{card.watcher.name || "(removed)"}: #{quoted(follow_up_name(card))} for " <>
      "#{post(outside)} did not start. " <> reason
  end

  @doc "The one line a follow-up's card becomes once the owner said no."
  @spec skipped(map()) :: String.t()
  def skipped(card), do: "Skipped #{quoted(follow_up_name(card))}; it did not run."

  @doc "The one line an approval's prompt becomes once the owner approved it."
  @spec approved(map()) :: String.t()
  def approved(card) do
    "Approved: #{quoted(card.job_name || "the follow-up")} runs on its own, at most " <>
      "#{card.daily_cap} a day."
  end

  @doc "The one line an approval's prompt becomes once the owner kept asking."
  @spec kept_asking(map()) :: String.t()
  def kept_asking(card),
    do: "Kept asking: each run of #{quoted(card.job_name || "the follow-up")} waits for your tap."

  # --- lines ----------------------------------------------------------------------------

  defp card(kind, lines, detail, actions, reply),
    do: %{kind: kind, lines: lines, detail: detail, actions: actions, reply: reply}

  defp follow_up_name(%{follow_up: follow_up}), do: follow_up.name || follow_up.job_id

  defp quoted(name), do: ~s("#{name}")

  # The item first, set as a quote so outside text looks quoted (§6.1).
  defp quote_line(outside, opts) do
    head = "❝ #{who(outside)}, #{age(outside, opts)}"

    case blank_to_nil(outside.text) do
      nil -> head
      text -> head <> ~s(: ") <> one_line(text, @quote_chars) <> ~s(")
    end
  end

  defp reason_line(reason) do
    case blank_to_nil(reason) do
      nil -> nil
      reason -> "Why: " <> one_line(reason, @reason_chars)
    end
  end

  defp who(outside),
    do: blank_to_nil(outside.subject) || blank_to_nil(outside.source_ref) || "An item"

  defp post(outside), do: who(outside) <> "'s post"

  defp age(outside, opts) do
    case outside.occurred_at || outside.received_at do
      nil -> "just now"
      at -> ago(DateTime.diff(now(opts), at, :second))
    end
  end

  defp ago(seconds) when seconds < 60, do: "just now"
  defp ago(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} min ago"
  defp ago(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)} h ago"
  defp ago(seconds), do: "#{div(seconds, 86_400)} d ago"

  # The item in the detail: where it came from, its subject and its text.
  defp item_lines(outside) do
    [
      "The item, from #{outside.source_ref || "a source"}:",
      blank_to_nil(outside.subject) && "Subject: " <> outside.subject,
      outside.text || ""
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "What sets an automatic follow-up off: the watcher's sources and the words it listens for."
  @spec set_off_by(map()) :: String.t()
  def set_off_by(%{sources: sources, listen_for: words})
      when is_list(sources) and is_list(words) do
    sources = Enum.join(sources, ", ")

    case words do
      [] -> sources
      words -> sources <> "; listens for " <> Enum.join(words, ", ")
    end
  end

  defp mandate_outside(proposal) do
    fields = snapshot_fields(Map.get(proposal, :snapshot))
    cue = proposal.cue

    %{
      source_ref: Map.get(cue, :source_ref),
      subject: fields["subject"] || Map.get(cue, :subject),
      text: fields["text"],
      occurred_at: Map.get(cue, :occurred_at),
      received_at: Map.get(cue, :received_at),
      reason: Map.get(cue, :decision_reason)
    }
  end

  defp snapshot_fields(nil), do: %{}

  defp snapshot_fields(snapshot) when is_binary(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, %{} = fields} -> Map.take(fields, ["subject", "text"])
      _not_json -> %{"text" => snapshot}
    end
  end

  # Every argument as `{name, text}`, in name order: a string as itself,
  # anything else as JSON.
  defp arguments(args) do
    args
    |> Enum.map(fn {name, value} -> {to_string(name), argument_text(value)} end)
    |> Enum.sort()
  end

  defp argument_text(value) when is_binary(value), do: value
  defp argument_text(value), do: Jason.encode!(value)

  # --- where it reports, and when ---------------------------------------------------------

  defp where(%{mode: mode, target: target}, opts) when mode in ["origin", "channel"] do
    if here?(target, Keyword.get(opts, :chat)), do: "here", else: "to " <> platform(target)
  end

  defp where(_delivery, _opts), do: "nowhere"

  @doc """
  Where a follow-up reports (`%{mode, target}`, its job's delivery): "this
  chat" when that is `opts[:chat]`, else the platform and its destination.
  """
  @spec reports_to(map(), keyword()) :: String.t()
  def reports_to(%{mode: mode, target: target} = delivery, opts)
      when mode in ["origin", "channel"] and is_list(opts) do
    case where(delivery, opts) do
      "here" -> "this chat"
      _elsewhere -> platform(target) <> destination(target)
    end
  end

  def reports_to(%{mode: _mode}, opts) when is_list(opts), do: "nowhere"

  defp here?(%{} = target, %{platform: platform, chat_id: chat_id}),
    do: target["platform"] == platform and to_string(target["chat_id"]) == chat_id

  defp here?(_target, _chat), do: false

  defp platform(%{"platform" => platform}), do: Map.get(@platform_names, platform, platform)
  defp platform(_target), do: "a chat"

  defp destination(%{} = target) do
    case Enum.find_value(~w(chat_id channel_id recipient target reply_target), &target[&1]) do
      nil -> ""
      destination -> " (#{destination})"
    end
  end

  defp time(nil, _opts), do: "soon"
  defp time(%DateTime{} = at, opts), do: Clock.stated_time(at, opts)

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  # One line: every run of whitespace a single space, then cut.
  defp one_line(nil, _max), do: ""

  defp one_line(text, max) when is_binary(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.trim() |> ProposalView.bounded(max)

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: text)
end
