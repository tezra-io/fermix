defmodule FermixCore.Jobs.HealCard do
  @moduledoc """
  A heal's proposal on its card (M106 §5.7, decision D5, stage S4b), and the
  card's place on the owner's answer rail (`Cues.Proposals`, whose third
  holder this is, `Cues.CardHolder`).

  The card is the approval card Fermix already sends for a watcher's
  proposal (`Cues.Card`, kind `:job_change`): its lines are the proposal's
  short ask (`Jobs.HealMessage.card_lines/2`: what failed, the diagnosis's
  note, one line per changed field, and that Fermix has not made it), its
  detail every changed field exactly, as it is and as it would become
  (`Jobs.HealMessage.change_detail/1`), and its answers Approve and Deny. A
  chat with buttons draws those; any other gets the whole card as text,
  ending with how to reply. Everything but the note is built by code from the
  stored change. A card is never cut: one whose whole text would pass
  `Cues.Card.max_chars/0` is never offered (`Jobs.HealDecision.fit_card/3`).

  The heal run binds the card to the chat its answer must come from before
  the first send (`Delivery.OwnerInbox.answer_origin/1`), under a `cp_` token
  stored as its digest, and every retry of the send carries that token
  (`Memory.Repo.JobHealsSql`). It sends through the rail's one card sender
  (`Cues.Proposals.send_card/3`).

  On the rail a heal's card answers by its token only from that chat and
  that user, or by its id (the heal's) from a bare answer in that chat while
  it waits there; a yes is `Jobs.HealAnswer.apply_change/4` and a no
  `leave/3`, recorded as answered from the rail's own label for a chat
  (`<platform>:<chat>:<user>`, `Memory.Repo.CuesSql.origin_text/1`), and the
  owner's reply is that module's sentence, which also says what became of a
  proposal that ended another way. It offers no Always allow. No model is
  between the answer and the change, and the cues feature need not be on.

  ## In the Fermix app (M106 §8, D12)

  When the owner's inbox is the app, the heal's message is a row in the
  app's timeline, as a told message is, ending with a line that it waits on
  its card (`app_row/1`), and its card is the approval card every app draws
  (`app_card/2`): the job by name and the change's short lines, the whole
  change in its detail, Approve and Deny. The card is bound to the app's
  origin (`Delivery.OwnerInbox.app_origin/1`), so it answers from the Mac
  chat and from a paired phone and from nowhere else.

  A chat's card and an app's card are answered two ways on purpose. A chat's
  card is a message that stays in the chat, sent once: its `cp_` token rides
  on it and is cleared when that send concludes. An app's card is no message:
  it is offered again from the record after every hello, an engine restart
  included (`app_cards/2`), so what it carries must come from the record. It
  is routed by the heal's id (`/confirm jhl_…`, the wire's `token`), which the
  rail answers only from the chat the card is bound to while it waits there,
  and which names the same card every time it is offered. Its lifetime is
  what is left of the seven days a proposal waits. Every end of a proposal
  bound to the app (approved, denied, and expired for any other: an edit, a
  pause or a resume of the job, the seven days, the job recovering, the job
  removed) is told to the app (`announce_ended/3`, `announce/3`), through
  the listener the channels application registers as
  `:app_approval_listener` (`heal_card_ended(profile, heal_id, outcome)`);
  core alone tells nobody.

  Seams (the rail's opts): `:repo`, `:now`, `:scheduler`, `:skill_registry`,
  `:capability_registry`, `:app_card_listener` (`fn profile, heal_id,
  outcome -> any end`).
  """

  @behaviour FermixCore.Cues.CardHolder

  require Logger

  alias FermixCore.Agents.SkillRegistry
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Cues.Card
  alias FermixCore.Cues.Proposals
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Jobs.HealAnswer
  alias FermixCore.Jobs.HealMessage
  alias FermixCore.Jobs.Scheduler
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql
  alias FermixCore.Memory.Repo.JobHealsSql

  @actions %{confirm: "Approve", deny: "Deny"}
  @reply "Reply /confirm to make this change, or /deny to leave the job as it is."
  @app_closing "Answer it on its card: Approve makes the change, Deny leaves the job as it is."
  @outcomes [:approved, :denied, :expired]
  @wrong_chat "Answer it from the chat Fermix sent it to; nothing was changed."
  @unknown "That card is not known to Fermix; nothing was changed."
  @unread "Nothing was changed: Fermix could not read that card."

  @doc """
  The card of a proposal: `lines`, its short ask as stored on the heal, and
  `change`, the stored change its detail shows whole.
  """
  @spec card([String.t()], map()) :: Card.t()
  def card([_first | _rest] = lines, change) when is_map(change) and map_size(change) > 0 do
    %{
      kind: :job_change,
      lines: lines,
      detail: HealMessage.change_detail(change),
      actions: @actions,
      reply: @reply
    }
  end

  @doc "How long the whole card is as one plain message: what its bound holds."
  @spec chars(Card.t()) :: non_neg_integer()
  def chars(card), do: card |> Card.text() |> String.length()

  @doc """
  The approval spec a channel delivers for the card of `heal` with its
  `token`: the send key of the heal's message rides with it
  (`Jobs.HealMessage.send_key/1`, the key its text would carry), so a channel
  whose helper answers a repeated send by its key (iMessage) never shows it
  twice.
  """
  @spec spec(Card.t(), String.t(), map()) :: FermixCore.Reply.approval_spec()
  def spec(card, token, %{id: _id, conclusion: _conclusion} = heal) when is_binary(token),
    do: card |> Card.spec(token) |> Map.put(:proactive_key, HealMessage.send_key(heal))

  @doc """
  What the history of the owner's chat keeps of a card: the lines and the
  detail as sent, without the reply line, the note left out
  (`Jobs.HealMessage.history_copy/2`).
  """
  @spec history_text(Card.t()) :: String.t()
  def history_text(%{lines: lines, detail: detail}),
    do: Enum.join(lines, "\n") <> "\n\n" <> detail

  # --- in the Fermix app (M106 §8, D12) ----------------------------------------------

  @doc """
  The row a proposal's message is in the app's timeline: the stored short
  ask (`message`, what failed, the note, the change's lines, that Fermix has
  not made it), then that it waits on its card. A row stays when the card is
  gone, so the timeline keeps what failed and what was proposed.
  """
  @spec app_row(String.t()) :: String.t()
  def app_row(message) when is_binary(message) and message != "",
    do: message <> "\n" <> @app_closing

  @doc """
  The card of a proposal in the app, standing alone beside its row: the job
  by name and each changed field's short line, every field whole in its
  detail, Approve and Deny. Built by code from the stored change.
  """
  @spec app_card(String.t(), map()) :: Card.t()
  def app_card(job_name, change)
      when is_binary(job_name) and is_map(change) and map_size(change) > 0 do
    %{
      kind: :job_change,
      lines: [
        title(job_name) | Enum.map(HealMessage.change_lines(change, :proposed), &("- " <> &1))
      ],
      detail: HealMessage.change_detail(change),
      actions: @actions,
      reply: @reply
    }
  end

  @doc """
  The approval spec the app is sent for heal `heal_id`'s `card`, routed by
  the heal's id (moduledoc), living `ttl_s` seconds.
  """
  @spec app_spec(Card.t(), String.t(), pos_integer()) :: FermixCore.Reply.approval_spec()
  def app_spec(card, "jhl_" <> _rest = heal_id, ttl_s) when is_integer(ttl_s) and ttl_s > 0,
    do: card |> Card.spec(heal_id) |> Map.put(:ttl_s, ttl_s)

  @doc "How long a proposal's card lives, in seconds: the days a proposal waits."
  @spec card_ttl_s() :: pos_integer()
  def card_ttl_s, do: JobHealsSql.waiting_days() * 86_400

  @doc """
  Every proposal waiting on its card in the app's chat `profile`, oldest
  first, as the spec it is offered again with after a hello (moduledoc),
  each living what is left of its seven days at `opts[:now]`. A card whose
  change cannot be read, or whose time is up, is not offered. Never raises:
  a store that is not running or does not answer is `{:error, reason}`.
  `opts`: `:repo`, `:now`.
  """
  @spec app_cards(String.t(), keyword()) ::
          {:ok, [FermixCore.Reply.approval_spec()]} | {:error, term()}
  def app_cards(profile, opts \\ []) when is_binary(profile) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, rows} <- read({:app_cards, OwnerInbox.app_origin(profile)}, opts) do
      {:ok, rows |> Enum.map(&offered(&1, now)) |> Enum.reject(&is_nil/1)}
    end
  end

  defp offered(%{change: change, job_name: name, waiting_since: %DateTime{} = since} = row, now)
       when is_map(change) and is_binary(name) do
    left_ms = DateTime.diff(DateTime.add(since, card_ttl_s(), :second), now, :millisecond)

    if left_ms > 0,
      do: name |> app_card(change) |> app_spec(row.id, div(left_ms + 999, 1_000)),
      else: nil
  end

  defp offered(_unreadable_or_unnamed, _now), do: nil

  @doc """
  Tells the app that each of heals `ids` whose card is bound to it ended
  with `outcome` (`approved`, `denied`, or `expired` for every other end).
  An approved card is told so once: its heal ending later, on a clean run or
  a fix that did not hold, is no second end of the card, so `expired` is
  told only of a card whose change was not made.
  A chat's card is told nothing: its own answer is its line. Never raises,
  and never fails its caller: what could not be read or told is logged, and
  an app offered the card again after its next hello no longer sees it.
  `opts`: `:repo` (and its call's `:timeout` and `:on_timeout`),
  `:app_card_listener`.
  """
  @spec announce_ended([String.t()], :approved | :denied | :expired, keyword()) :: :ok
  def announce_ended(ids, outcome, opts \\ [])

  def announce_ended([], outcome, _opts) when outcome in @outcomes, do: :ok

  def announce_ended(ids, outcome, opts) when is_list(ids) and outcome in @outcomes do
    case read({cards_read(outcome), ids}, opts) do
      {:ok, cards} -> announce(cards, outcome, opts)
      {:error, reason} -> log_untold(ids, outcome, reason)
    end
  end

  defp cards_read(:expired), do: :unapplied_cards_among
  defp cards_read(answer) when answer in [:approved, :denied], do: :cards_among

  @doc """
  The cards of `job_id`'s proposals still waiting, read before the job is
  removed (its heals go with it), for `announce/3` after. `[]`, logged,
  when they cannot be read. `opts`: `:repo`.
  """
  @spec waiting_cards_of_job(String.t(), keyword()) :: [map()]
  def waiting_cards_of_job(job_id, opts \\ []) when is_binary(job_id) and is_list(opts) do
    case read({:waiting_cards_of_job, job_id}, opts) do
      {:ok, cards} ->
        cards

      {:error, reason} ->
        log_untold([job_id], :expired, reason)
        []
    end
  end

  @doc """
  Tells the app of each card in `cards` (`%{id, origin}`, as the store reads
  them) bound to it that its proposal ended with `outcome`. `opts`:
  `:app_card_listener`.
  """
  @spec announce([map()], :approved | :denied | :expired, keyword()) :: :ok
  def announce(cards, outcome, opts) when is_list(cards) and outcome in @outcomes do
    listener = Keyword.get_lazy(opts, :app_card_listener, &registered_listener/0)

    for %{id: id, origin: origin} <- cards, app_bound?(origin), listener != nil do
      tell(listener, origin.chat_id, id, outcome)
    end

    :ok
  end

  # Bound to the app: the origin an answer typed in the app carries, by the
  # one rule that says so.
  defp app_bound?(%{platform: platform, chat_id: chat_id} = origin)
       when is_binary(platform) and is_binary(chat_id),
       do: OwnerInbox.answered_in_app(platform, chat_id) == {:ok, origin}

  defp app_bound?(_origin), do: false

  defp tell(listener, profile, heal_id, outcome) do
    listener.(profile, heal_id, outcome)
  catch
    kind, reason ->
      Logger.error(
        "Job heal #{heal_id}: the app was not told its card ended (#{outcome}): " <>
          Exception.format_banner(kind, reason)
      )
  end

  # The channels application registers its listener; nil while it does not
  # run (a tree-less CLI, core alone), when no app is there to tell.
  defp registered_listener do
    case Application.get_env(:fermix_core, :app_approval_listener) do
      nil -> nil
      module when is_atom(module) -> &module.heal_card_ended/3
    end
  end

  defp log_untold(ids, outcome, reason) do
    Logger.error(
      "Job heals #{Enum.join(ids, ", ")}: whether the app shows their cards could not be read, " <>
        "so it was not told they ended (#{outcome}): #{inspect(reason)}"
    )
  end

  # A store that is not running (an engine that opens no database) or that
  # does not answer is an error to say, never an exit in the caller.
  defp read(request, opts) do
    repo = Keyword.get(opts, :repo, Repo)
    call_opts = [server: repo] ++ Keyword.take(opts, [:timeout, :on_timeout])

    if GenServer.whereis(repo),
      do: Repo.job_heals_call(request, call_opts),
      else: {:error, :repo_not_running}
  catch
    :exit, reason -> {:error, {:repo_exit, reason}}
  end

  defp title(name), do: ~s(Change job "#{HealMessage.shown_name(name)}"?)

  # --- the answer rail (`Cues.CardHolder`) ------------------------------------------

  @impl true
  def card_kind, do: :job_heal

  @impl true
  def card_id_prefix, do: "jhl_"

  @impl true
  def offers_always_allow?, do: false

  @impl true
  def holds_token?(digest, opts) when is_binary(digest) and is_list(opts),
    do: Repo.job_heals_call({:card_held, digest}, repo(opts))

  @impl true
  def answer_card({:token, token}, decision, origin, opts) when is_binary(token) do
    case Repo.job_heals_call({:card_by_digest, Proposals.digest(token)}, repo(opts)) do
      {:ok, %{id: id, origin: ^origin}} -> answer(id, decision, origin, opts)
      {:ok, %{id: _id}} -> {:error, @wrong_chat}
      {:ok, nil} -> {:error, @unknown}
      {:error, _reason} -> {:error, @unread}
    end
  end

  def answer_card({:id, id}, decision, origin, opts) when is_binary(id),
    do: answer(id, decision, origin, opts)

  @impl true
  def waiting_in_chat_cards(origin, opts) when is_map(origin) and is_list(opts) do
    with {:ok, cards} <- Repo.job_heals_call({:cards_in_chat, origin}, repo(opts)) do
      {:ok, Enum.map(cards, &waiting/1)}
    end
  end

  defp waiting(%{id: id, job_name: name}),
    do: %{kind: :job_heal, id: id, title: title(name || "")}

  # A yes applies the recorded change; a no leaves it. Each says, in
  # `HealAnswer`'s words, what it did or why it did nothing, and tells an app
  # that shows the card how it ended.
  defp answer(id, :confirm, origin, opts) do
    answer_opts = [scheduler: Keyword.get(opts, :scheduler, Scheduler)] ++ ended_opts(opts)

    id
    |> HealAnswer.apply_change(CuesSql.origin_text(origin), checks(opts), answer_opts)
    |> reply()
  end

  defp answer(id, :deny, origin, opts),
    do:
      id
      |> HealAnswer.leave(CuesSql.origin_text(origin), checks(opts), ended_opts(opts))
      |> reply()

  defp ended_opts(opts), do: Keyword.take(opts, [:app_card_listener])

  defp reply({:ok, _done, sentence}), do: {:ok, sentence}
  defp reply({:error, _reason, sentence}), do: {:error, sentence}

  # What the answer's checks read: an owner's edit's.
  defp checks(opts) do
    %{
      repo: Keyword.get(opts, :repo, Repo),
      skill_registry: Keyword.get(opts, :skill_registry, SkillRegistry),
      capability_registry: Keyword.get(opts, :capability_registry, CapabilityRegistry),
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    }
  end

  defp repo(opts), do: [server: Keyword.get(opts, :repo, Repo)]
end
