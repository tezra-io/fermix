defmodule FermixCore.Cues.ProposalView do
  @moduledoc """
  What every app surface shows of a proposal (M60 app surface §3.4, §3.7):
  Fermix's record, and the card the owner decides from. Pure: it shapes a row
  `CuesMandateSql` read (`{:proposal_card, id}`, `{:proposal_cards, …}`).

  The **record** is Fermix's alone: ids, names from the owner's own
  configuration (the mandate, the task, the watcher, the source), times, where
  the answer came from, and Fermix's sentence. No argument and no cue text.

  The **card** is the record plus when Fermix received the cue, `summary`
  (Fermix's sentence, no outside text in it) and `outside`: everything a model
  or a stranger wrote, kept apart by structure, never by markup. `args_text` is
  the recorded call's arguments as pretty JSON, never cut: a call over the
  3,500-character cap was refused before it was stored (`Cues.Proposals`), and
  the companion wire refuses a card over it; `cue` is the cue's snapshot
  (`type`, `subject`, `text`) with the producer's `occurred_at`, or nil when
  Fermix no longer keeps it. The engine's `UntrustedContent.frame/2` preamble
  is for models and never crosses to an app. The Mac's chat draws the compact
  card (`compact_card/1`, M60_WATCHER_CODING_RUNS.md §6.3), which adds
  `outside.args`, each argument as `name` and `value` (a string as itself,
  anything else as JSON), and `outside.reason`, the filter's reason for
  passing the item.

  ## A watcher's follow-up (M60_WATCHER_CODING_RUNS.md §6.2)

  A follow-up's card (`follow_up_card/2`, from `Cues.FollowUps.card/2`) is a
  card of the same shape, keyed by the trigger's id, with `follow_up` in
  place of `mandate`, `tool` and the call's arguments: the follow-up's
  `name`, the owner's `instructions`, its `tools`, where it `reports_to`, what
  the card `asks` (`run`, once now), and `offers_always_allow`, which says
  the card also takes Always allow (the 2026-10-31 revision of §3.4): run
  this one, and the follow-up's later items with no card. Its states read as
  a proposal's: `starting` and `started` are `confirmed`, `skipped` is
  `denied`.

  Times are RFC 3339 UTC strings to the second; every field is present, nil
  where it does not apply.
  """

  alias FermixCore.Cues.Card

  @max_args_chars 3_500

  @typedoc "Fermix's record of a proposal (app surface §3.4)."
  @type record :: %{
          proposal_id: String.t(),
          state: String.t(),
          mandate: String.t(),
          tool: String.t(),
          task: %{job_id: String.t(), name: String.t() | nil},
          watcher: String.t() | nil,
          source_ref: String.t() | nil,
          created_at: String.t(),
          expires_at: String.t(),
          decided_at: String.t() | nil,
          decided_from: String.t() | nil,
          result_status: String.t() | nil,
          status_sentence: String.t()
        }

  @typedoc "The cue a proposal acted on, from its snapshot: outside text, every field."
  @type cue :: %{
          type: String.t() | nil,
          subject: String.t() | nil,
          text: String.t() | nil,
          occurred_at: String.t() | nil
        }

  @typedoc """
  The card (app surface §3.7): the record, `received_at`, `summary` and
  `outside`; a follow-up's card carries `follow_up` too.
  """
  @type card :: %{
          required(:proposal_id) => String.t(),
          required(:received_at) => String.t() | nil,
          required(:summary) => String.t(),
          required(:outside) => map(),
          optional(atom()) => term()
        }

  @doc "The longest `outside.args_text` a card may carry, in characters (never cut to it)."
  @spec max_args_chars() :: pos_integer()
  def max_args_chars, do: @max_args_chars

  @doc "Fermix's record of the proposal `row`."
  @spec record(map()) :: record()
  def record(%{id: id, state: state} = row) when is_binary(id) and is_binary(state) do
    %{
      proposal_id: id,
      state: state,
      mandate: row.mandate,
      tool: row.tool,
      task: %{job_id: row.job_id, name: row.job_name},
      watcher: row.watcher,
      source_ref: row.source_ref,
      created_at: time(row.created_at),
      expires_at: time(row.expires_at),
      decided_at: time(row.decided_at),
      decided_from: surface(row.decided_from),
      result_status: row.result_status,
      status_sentence: status_sentence(row)
    }
  end

  @doc "The card of the proposal `row`: its record, Fermix's sentence and the outside text apart."
  @spec card(map()) :: card()
  def card(%{id: id} = row) when is_binary(id) do
    row
    |> record()
    |> Map.merge(%{
      received_at: time(row.received_at),
      summary:
        "A task wants to run #{row.tool} under your mandate #{row.mandate}. It runs only if " <>
          "you confirm.",
      outside: %{args_text: args_text(row.args_json), cue: cue(row.snapshot, row.occurred_at)}
    })
  end

  @doc """
  The card of the proposal `row` as the Mac's chat draws it (the companion
  wire): `card/1`, with `outside.args` and `outside.reason` for the compact
  card's lines (M60_WATCHER_CODING_RUNS.md §6.3), and no `follow_up`.
  """
  @spec compact_card(map()) :: card()
  def compact_card(%{id: id} = row) when is_binary(id) do
    card = card(row)

    outside =
      Map.merge(card.outside, %{
        args: args(row.args_json),
        reason: Map.get(row, :decision_reason)
      })

    Map.merge(card, %{outside: outside, follow_up: nil})
  end

  @doc """
  The card of a follow-up's trigger (`Cues.FollowUps.card/2`): Fermix's
  record, the follow-up, and the item and the filter's reason apart.
  """
  @spec follow_up_card(map(), keyword()) :: card()
  def follow_up_card(%{trigger_id: id, follow_up: follow_up, outside: outside} = card, opts)
      when is_binary(id) and is_list(opts) do
    state = follow_up_state(card.state)

    %{
      proposal_id: id,
      state: state,
      mandate: nil,
      tool: nil,
      task: %{job_id: follow_up.job_id, name: follow_up.name},
      watcher: card.watcher.name,
      source_ref: outside.source_ref,
      created_at: time(card.created_at),
      expires_at: time(card.expires_at),
      decided_at: time(card.decided_at),
      decided_from: surface(card.decided_from),
      result_status: nil,
      status_sentence: follow_up_sentence(state, card),
      received_at: time(outside.received_at),
      summary:
        "Watcher #{card.watcher.name || "(removed)"} wants to run its follow-up " <>
          "#{quoted(follow_up.name)}. It runs only if you confirm.",
      outside: %{
        reason: outside.reason,
        cue: follow_up_cue(outside)
      },
      follow_up: %{
        asks: "run",
        offers_always_allow: true,
        name: follow_up.name || follow_up.job_id,
        instructions: follow_up.instructions,
        tools: follow_up.tools,
        reports_to: Card.reports_to(follow_up.delivery, opts)
      }
    }
  end

  @doc "The state a follow-up's trigger shows as a card's (`starting` is `confirmed`)."
  @spec follow_up_state(String.t()) :: String.t()
  def follow_up_state("waiting"), do: "waiting"
  def follow_up_state(state) when state in ["starting", "started"], do: "confirmed"
  def follow_up_state("skipped"), do: "denied"
  def follow_up_state(state) when state in ["expired", "refused"], do: state

  @doc """
  `text` cut to at most `max` characters, its last one an ellipsis when cut;
  nil stays nil.
  """
  @spec bounded(String.t() | nil, pos_integer()) :: String.t() | nil
  def bounded(nil, _max), do: nil

  def bounded(text, max) when is_binary(text) and is_integer(max) and max > 1 do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

  # Where the answer came from, by its surface alone: a chat's stored origin is
  # `<platform>:<chat>:<user>`, a phone's `mobile:<device>`.
  defp surface(nil), do: nil
  defp surface(decided_from), do: decided_from |> String.split(":", parts: 2) |> hd()

  defp status_sentence(%{state: "waiting"}),
    do: "Waiting for your answer; it runs only if you confirm."

  defp status_sentence(%{state: "confirmed", result_status: nil, tool: tool}),
    do: "Confirmed; #{tool} is running."

  defp status_sentence(%{state: "confirmed", result_status: "ok", tool: tool}),
    do: "Confirmed; #{tool} ran."

  defp status_sentence(%{state: "confirmed", result_status: "unknown", tool: tool}),
    do: "Confirmed, but #{tool} stopped before it reported, so whether it ran is unknown."

  defp status_sentence(%{state: "confirmed", tool: tool}), do: "Confirmed, but #{tool} failed."
  defp status_sentence(%{state: "denied", tool: tool}), do: "Denied; #{tool} did not run."
  defp status_sentence(%{state: "expired"}), do: "Expired with no answer; nothing ran."

  # Refused before anyone answered: the send to the owner's chat failed and no
  # app could show it.
  defp status_sentence(%{state: "refused", decided_from: nil}),
    do: "Fermix could not reach you, so the proposal was not sent."

  defp status_sentence(%{state: "refused"}),
    do: "Not run: Fermix's checks refused it when you confirmed."

  defp follow_up_sentence("waiting", _card),
    do: "Waiting for your answer; it runs only if you confirm."

  defp follow_up_sentence("confirmed", %{always_allow: "allowed"}),
    do: "Confirmed; the follow-up is starting, and runs with no card from now on."

  defp follow_up_sentence("confirmed", _card), do: "Confirmed; the follow-up is starting."
  defp follow_up_sentence("denied", _card), do: "Skipped; the follow-up did not run."
  defp follow_up_sentence("expired", _card), do: "Expired with no answer; nothing ran."
  defp follow_up_sentence("refused", %{reason: reason}) when is_binary(reason), do: reason
  defp follow_up_sentence("refused", _card), do: "Not run: Fermix refused it."

  defp follow_up_cue(%{type: nil, subject: nil, text: nil}), do: nil

  defp follow_up_cue(outside) do
    %{
      type: outside.type,
      subject: outside.subject,
      text: outside.text,
      occurred_at: time(outside.occurred_at)
    }
  end

  defp quoted(name), do: ~s("#{name}")

  # Each argument as `name` and `value`, in name order: a string as itself,
  # anything else as JSON.
  defp args(args_json) do
    case Jason.decode(args_json) do
      {:ok, %{} = args} ->
        args
        |> Enum.map(fn {name, value} -> %{name: name, value: arg_value(value)} end)
        |> Enum.sort_by(& &1.name)

      _not_an_object ->
        []
    end
  end

  defp arg_value(value) when is_binary(value), do: value
  defp arg_value(value), do: Jason.encode!(value)

  # The arguments as `Cues.Proposals` shows them in a chat: pretty JSON, whole.
  defp args_text(args_json) do
    case Jason.decode(args_json) do
      {:ok, %{} = args} -> Jason.encode!(args, pretty: true)
      _not_an_object -> args_json
    end
  end

  defp cue(nil, _occurred_at), do: nil

  defp cue(snapshot, occurred_at) when is_binary(snapshot) do
    case Jason.decode(snapshot) do
      {:ok, %{} = fields} ->
        %{
          type: text_field(fields, "type"),
          subject: text_field(fields, "subject"),
          text: text_field(fields, "text"),
          occurred_at: time(occurred_at)
        }

      _not_json ->
        %{type: nil, subject: nil, text: snapshot, occurred_at: time(occurred_at)}
    end
  end

  defp text_field(fields, key) do
    case Map.get(fields, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp time(nil), do: nil

  defp time(%DateTime{} = at),
    do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
