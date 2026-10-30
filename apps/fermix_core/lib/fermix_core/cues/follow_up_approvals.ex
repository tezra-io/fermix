defmodule FermixCore.Cues.FollowUpApprovals do
  @moduledoc """
  The prompt that lets an automatic follow-up run on its own
  (M60_WATCHER_CODING_RUNS.md §3.4, §5). An automatic follow-up is written
  unapproved, and any change to what it runs or what sets it off clears its
  approval (`Cues.Watchers`), so until the owner approves it, each run asks
  first on a card. `ask/2` sends the prompt that approves it.

  The prompt goes the way a follow-up's card goes: a row in
  `cue_follow_up_approvals` (`Memory.Repo.CuesFollowUpSql`) holding the digest
  it showed (`Cues.Watchers.current_follow_up_digest/2`), the message and the
  `cp_` token written by the sender the channels application registers as
  `:cue_follow_up_sender` (`Cues.Card.approval/2`), where it went, and an
  expiry of 30 minutes; every app surface is offered it
  (`Cues.ProposalView.approval_card/2`). One prompt waits per watcher: a new
  one expires the one before it.

  The owner answers by token from that chat (`confirm/3`, `deny/3`, which
  `Cues.Proposals` dispatches to), by id from an app or a bare `/confirm`
  (`decide/4`). The answer is recorded on the row, fenced on `waiting`, the
  expiry and, by token, the chat; a yes is then applied by
  `Cues.Watchers.approve_follow_up/3` with the digest the prompt showed, so it
  approves only what the owner read: a change since then approves nothing.
  A no keeps the follow-up asking first. Nobody's answer expires the prompt
  (`expire/3`, a `Cues.Sweeper` step). Each step is traced under the watcher.

  Seams (opts): `:repo`, `:now`, `:follow_up_sender`, `:proposal_listener`,
  and `Cues.Watchers`' seams.
  """

  require Logger

  alias FermixCore.Cues
  alias FermixCore.Cues.Card
  alias FermixCore.Cues.Proposals
  alias FermixCore.Cues.ProposalView
  alias FermixCore.Cues.Telemetry
  alias FermixCore.Cues.Watchers
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesFollowUpSql

  @approve_within_s 30 * 60
  @app_origins ["companion", "management"]
  @max_device_id_bytes 128
  @unread "Fermix recorded your answer but could not read the prompt back."

  @typedoc "An approval's prompt as `CuesFollowUpSql` reads it."
  @type approval :: CuesFollowUpSql.approval()

  @doc "How long a prompt waits for the owner, in seconds."
  @spec approve_within_s() :: pos_integer()
  def approve_within_s, do: @approve_within_s

  @doc """
  Sends watcher `name`'s automatic follow-up its approval prompt, bound to
  what it runs and what sets it off now. Answers Fermix's sentence for the
  owner's turn; refused for a follow-up that asks first.
  """
  @spec ask(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def ask(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with {:ok, watcher} <- Watchers.show(name, opts),
         :ok <- automatic(watcher),
         {:ok, digest} <- Watchers.current_follow_up_digest(name, opts),
         {:ok, approval} <- insert(watcher, digest, opts),
         {:ok, card} <- read_card(approval.id, opts) do
      send_prompt(approval, card, opts)
    end
  end

  defp automatic(%{follow_up_mode: "auto"}), do: :ok

  defp automatic(%{follow_up_mode: nil, name: name}),
    do: {:error, "Watcher #{name} has no follow-up."}

  defp automatic(%{name: name}),
    do: {:error, "Watcher #{name}'s follow-up asks first; make it automatic first."}

  defp insert(watcher, digest, opts) do
    now = now(opts)

    row = %{
      id: Cues.id("cfa"),
      watcher_id: watcher.id,
      shown_digest: digest,
      expires_at: DateTime.add(now, @approve_within_s, :second)
    }

    case repo_call({:ask_approval, row, now}, opts) do
      {:ok, {approval, superseded}} ->
        Enum.each(superseded, &ended(&1, opts))
        emit(:follow_up_approval_asked, approval, %{})
        {:ok, approval}

      {:error, reason} ->
        failed("asked", reason)
    end
  end

  # The sender writes the message and the token and says where it went; a
  # prompt it could send nowhere stays for an app that connects within its
  # lifetime, and the owner's turn is told it did not reach a chat.
  defp send_prompt(approval, card, opts) do
    case guarded_send(sender(opts), card) do
      {:ok, binding} when is_map(binding) ->
        record_offer(approval, card, binding, opts)

      {:error, reason} ->
        Logger.warning("Approval prompt #{approval.id} was not sent: #{inspect(reason)}")
        {:error, "Fermix could not reach you, so the approval was not asked."}
    end
  end

  defp record_offer(approval, card, binding, opts) do
    case repo_call({:record_approval_offer, approval.id, binding}, opts) do
      {:ok, _offered} ->
        Proposals.announce({:offered, ProposalView.approval_card(card, opts)}, opts)
        {:ok, asked_sentence(binding)}

      {:error, reason} ->
        failed("recorded", reason)
    end
  end

  defp asked_sentence(%{platform: platform}) when is_binary(platform),
    do: "Fermix sent you a prompt to approve it; until you do, each run asks first."

  defp asked_sentence(_app_only),
    do: "The Fermix app shows a prompt to approve it; until you do, each run asks first."

  # A sender that raises is a send that failed; its stacktrace is logged.
  defp guarded_send(nil, _card), do: {:error, :no_follow_up_sender}

  defp guarded_send(send_fun, card) do
    send_fun.(card)
  catch
    kind, reason ->
      Logger.error(
        "The approval prompt's sender crashed: " <>
          (kind |> Exception.format(reason, __STACKTRACE__) |> String.slice(0, 4_000))
      )

      {:error, {:sender_crashed, kind}}
  end

  # The channels application registers its sender module; nil while it is not
  # running (a tree-less CLI, a test of core alone).
  defp sender(opts) do
    Keyword.get_lazy(opts, :follow_up_sender, fn ->
      case Application.get_env(:fermix_core, :cue_follow_up_sender) do
        nil -> nil
        module when is_atom(module) -> &module.send_follow_up/1
      end
    end)
  end

  # --- answers ---------------------------------------------------------------------------

  @doc """
  The owner's yes by token from `origin` (`%{platform, chat_id, user_id}`):
  recorded on the prompt, fenced on the token, `waiting`, the chat it went to
  and the expiry, then applied with the digest the prompt showed. Returns the
  one line the prompt becomes.
  """
  @spec confirm(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def confirm(token, origin, opts \\ []) when is_binary(token) and is_map(origin),
    do: answer({:answer_approval, Proposals.digest(token), origin, "approved", now(opts)}, opts)

  @doc "The owner's no by token from `origin`: the follow-up keeps asking first."
  @spec deny(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def deny(token, origin, opts \\ []) when is_binary(token) and is_map(origin),
    do: answer({:answer_approval, Proposals.digest(token), origin, "denied", now(opts)}, opts)

  @doc """
  An answer by id from one of the owner's apps (`companion`, `management`,
  `mobile:<device>`) or from a chat whose waiting prompt `waiting_in_chat/2`
  resolved (`<platform>:<chat>:<user>`), fenced on `waiting` and the expiry.
  """
  @spec decide(String.t(), :confirm | :deny, String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def decide(approval_id, decision, origin_label, opts \\ [])
      when is_binary(approval_id) and decision in [:confirm, :deny] and is_binary(origin_label) do
    with :ok <- known_origin(origin_label) do
      answer({:decide_approval, approval_id, to_state(decision), origin_label, now(opts)}, opts)
    end
  end

  defp answer(request, opts) do
    case repo_call(request, opts) do
      {:ok, approval} -> approval |> apply_answer(opts) |> tap(&ended(approval, &1, opts))
      {:error, why} -> {:error, refusal_reply(why)}
    end
  end

  # A yes approves only the digest the prompt showed; the watcher is read by
  # name, so one removed meanwhile approves nothing.
  defp apply_answer(%{state: "approved", watcher_name: nil}, _opts),
    do: {:error, "That watcher is gone; nothing was approved."}

  defp apply_answer(%{state: "approved"} = approval, opts) do
    with {:ok, _approved} <-
           Watchers.approve_follow_up(approval.watcher_name, approval.shown_digest, opts) do
      line(approval, &Card.approved/1, opts)
    end
  end

  defp apply_answer(%{state: "denied"} = approval, opts),
    do: line(approval, &Card.kept_asking/1, opts)

  defp line(approval, card_line, opts) do
    case read_card(approval.id, opts) do
      {:ok, card} ->
        {:ok, card_line.(card)}

      {:error, reason} ->
        Logger.error("Approval #{approval.id} answered, then not read back: #{inspect(reason)}")
        {:error, @unread}
    end
  end

  defp to_state(:confirm), do: "approved"
  defp to_state(:deny), do: "denied"

  # Where an answer by id may come from: an app, a phone, or a chat's origin.
  defp known_origin(label) when label in @app_origins, do: :ok

  defp known_origin("mobile:" <> device)
       when device != "" and byte_size(device) <= @max_device_id_bytes,
       do: :ok

  defp known_origin(label) do
    case String.split(label, ":", parts: 3) do
      [platform, chat, user] when platform != "" and chat != "" and user != "" -> :ok
      _other -> {:error, "Fermix does not know where that answer came from; nothing changed."}
    end
  end

  defp refusal_reply(:unknown), do: "That prompt is not known to Fermix; nothing was approved."
  defp refusal_reply(:wrong_origin), do: "Answer it from the chat Fermix sent it to."
  defp refusal_reply(:expired), do: "That prompt expired; each run still asks first."
  defp refusal_reply({:not_waiting, "approved"}), do: "That prompt was already approved."
  defp refusal_reply({:not_waiting, "denied"}), do: "That prompt was already answered."

  defp refusal_reply({:not_waiting, "expired"}),
    do: "That prompt expired; each run still asks first."

  defp refusal_reply(:disabled), do: "Cues keep their records in memory, which is off."

  defp refusal_reply(reason) do
    Logger.error("Approval answer failed: #{inspect(reason)}")
    "Fermix could not read that prompt; nothing was approved."
  end

  @doc """
  The prompts waiting in the chat `origin` (`%{platform, chat_id, user_id}`),
  oldest first: what a bare `/confirm` or `/deny` from it may answer.
  """
  @spec waiting_in_chat(map(), keyword()) :: {:ok, [approval()]} | {:error, term()}
  def waiting_in_chat(origin, opts \\ []) when is_map(origin) and is_list(opts),
    do: repo_call({:approvals_waiting_in_chat, origin, now(opts)}, opts)

  # --- reads --------------------------------------------------------------------------------

  @doc """
  What prompt `approval_id` shows: the prompt, the watcher's name, daily cap,
  sources and words, and the follow-up's name, instructions, tools and
  delivery, as stored now.
  """
  @spec card(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found | term()}
  def card(approval_id, opts \\ []) when is_binary(approval_id) and is_list(opts),
    do: read_card(approval_id, opts)

  defp read_card(id, opts) do
    case repo_call({:approval_card, id}, opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, card} -> {:ok, card}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Every prompt still waiting, oldest first, as an app shows it."
  @spec waiting_cards(pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def waiting_cards(limit, opts \\ []) when is_integer(limit) and limit > 0 and is_list(opts) do
    with {:ok, cards} <- repo_call({:waiting_approval_cards, now(opts), limit}, opts),
         do: {:ok, Enum.map(cards, &ProposalView.approval_card(&1, opts))}
  end

  @doc """
  The `Cues.Sweeper` step: prompts past their expiry become `expired`; the
  follow-up keeps asking first. Each is traced and told to every app surface.
  """
  @spec expire(keyword(), DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def expire(repo_opts, %DateTime{} = now, limit)
      when is_list(repo_opts) and is_integer(limit) and limit > 0 do
    with {:ok, expired} <-
           Repo.cues_call(CuesFollowUpSql, {:expire_approvals, now, limit}, repo_opts) do
      Enum.each(expired, &ended(&1, repo_opts))
      {:ok, length(expired)}
    end
  end

  # --- traces and announcements --------------------------------------------------------------

  # A prompt that left `waiting` without an answer (expired, or a new prompt
  # took its place).
  defp ended(approval, opts) do
    emit(:follow_up_approval_expired, approval, %{})
    sentence = "That prompt expired; each run still asks first."
    announce_end(approval, sentence, opts)
  end

  # An answer, with the line it came to.
  defp ended(approval, result, opts) do
    {_tag, sentence} = result
    emit(:follow_up_approval_decided, approval, %{kind: origin_kind(approval.decided_from)})
    announce_end(approval, sentence, opts)
  end

  defp announce_end(approval, sentence, opts) do
    resolved = %{
      proposal_id: approval.id,
      state: ProposalView.approval_state(approval.state),
      result_status: nil,
      sentence: sentence,
      result_text: nil
    }

    Proposals.announce({:resolved, resolved}, opts)
  end

  defp origin_kind(nil), do: nil
  defp origin_kind(label), do: label |> String.split(":", parts: 2) |> hd()

  defp emit(phase, approval, extra) do
    metadata =
      %{proposal_id: approval.id, watcher_id: approval.watcher_id, state: approval.state}
      |> Map.merge(extra)
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    Telemetry.lifecycle(phase, %{}, metadata)
  end

  defp failed(step, reason) do
    Logger.error("An approval prompt was not #{step}: #{inspect(reason)}")
    {:error, "Fermix could not ask for the approval; nothing was approved."}
  end

  # --- plumbing -------------------------------------------------------------------------------

  defp repo_call(request, opts) do
    repo_opts =
      [server: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:timeout, :on_timeout])

    Repo.cues_call(CuesFollowUpSql, request, repo_opts)
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
