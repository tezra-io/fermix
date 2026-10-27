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
  the companion wire refuses a card over it; `cue` is the cue's
  snapshot (`type`, `subject`, `text`) with the producer's `occurred_at`, or nil
  when Fermix no longer keeps it. The engine's `UntrustedContent.frame/2`
  preamble is for models and never crosses to an app.

  Times are RFC 3339 UTC strings to the second; every field is present, nil
  where it does not apply.
  """

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

  @typedoc "The card (app surface §3.7): the record, `received_at`, `summary` and `outside`."
  @type card :: %{
          required(:proposal_id) => String.t(),
          required(:received_at) => String.t() | nil,
          required(:summary) => String.t(),
          required(:outside) => %{args_text: String.t(), cue: cue() | nil},
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
