defmodule FermixCore.Cues.FollowUpCards do
  @moduledoc """
  What a follow-up's card (`Cues.FollowUps`) and an automatic follow-up's
  approval prompt (`Cues.FollowUpApprovals`) share on their way to the owner
  and back (M60_WATCHER_CODING_RUNS.md §4.5, §5):

    * `send_card/2` hands a card to the sender the channels application registers
      as `:cue_follow_up_sender`, which writes the message and the `cp_` token
      and answers where it went. A sender that raises is a send that failed:
      it is logged with its stacktrace and every `cp_` token taken out, as
      `Cues.Proposals` does with a proposal's.
    * `known_origin/1` and `origin_kind/1` check where an answer by id came
      from: an app, a phone, or a chat's `<platform>:<chat>:<user>`.
    * `refusal_reply/2` is Fermix's sentence for an answer that changed
      nothing, in a card's or a prompt's words.
    * `repo_call/3` and `now/1`: the Repo call and the clock both use.

  Seams (opts): `:follow_up_sender` (`fn card -> {:ok, binding} | {:error,
  reason} end`), `:repo`, `:timeout`, `:on_timeout`, `:now`.
  """

  require Logger

  alias FermixCore.Memory.Repo

  @app_origins ["companion", "management"]
  @max_device_id_bytes 128
  @token ~r/cp_[A-Za-z0-9_-]+/

  @typedoc "What an answer refused: a run's card or an approval's prompt."
  @type asks :: :card | :prompt

  @doc """
  Hands `card` (`Cues.FollowUps.card/2` or `Cues.FollowUpApprovals.card/2`) to
  the registered sender, which answers where it went. No sender (a tree-less
  CLI, a test of core alone) is `{:error, :no_follow_up_sender}`; one that
  raises is logged, its tokens scrubbed, and is `{:error, {:sender_crashed,
  kind}}`.
  """
  @spec send_card(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def send_card(card, opts) when is_map(card) and is_list(opts),
    do: guarded_send(sender(opts), card)

  defp guarded_send(nil, _card), do: {:error, :no_follow_up_sender}

  defp guarded_send(send_fun, card) do
    send_fun.(card)
  catch
    kind, reason ->
      formatted =
        kind
        |> Exception.format(reason, __STACKTRACE__)
        |> String.replace(@token, "cp_…")
        |> String.slice(0, 4_000)

      Logger.error("The follow-up sender crashed: " <> formatted)
      {:error, {:sender_crashed, kind}}
  end

  # The channels application registers its sender module; nil while it is not
  # running.
  defp sender(opts) do
    Keyword.get_lazy(opts, :follow_up_sender, fn ->
      case Application.get_env(:fermix_core, :cue_follow_up_sender) do
        nil -> nil
        module when is_atom(module) -> &module.send_follow_up/1
      end
    end)
  end

  @doc """
  Whether an answer by id may come from `label`: one of the owner's apps
  (`companion`, `management`), a phone (`mobile:<device>`), or a chat whose
  waiting card a bare `/confirm` resolved (`<platform>:<chat>:<user>`).
  """
  @spec known_origin(String.t()) :: :ok | {:error, String.t()}
  def known_origin(label) when label in @app_origins, do: :ok

  def known_origin("mobile:" <> device)
      when device != "" and byte_size(device) <= @max_device_id_bytes,
      do: :ok

  def known_origin(label) when is_binary(label) do
    case String.split(label, ":", parts: 3) do
      [platform, chat, user] when platform != "" and chat != "" and user != "" -> :ok
      _other -> {:error, "Fermix does not know where that answer came from; nothing changed."}
    end
  end

  @doc "The kind of surface an answer came from, for its trace: the label's first part."
  @spec origin_kind(String.t() | nil) :: String.t() | nil
  def origin_kind(nil), do: nil
  def origin_kind(label) when is_binary(label), do: label |> String.split(":", parts: 2) |> hd()

  @doc """
  Fermix's sentence for an answer that changed nothing, `why` as the Repo gave
  it, in a run's card's words (`:card`) or an approval prompt's (`:prompt`).
  A reason it does not know is logged.
  """
  @spec refusal_reply(term(), asks()) :: String.t()
  def refusal_reply(:disabled, _asks), do: "Cues keep their records in memory, which is off."

  def refusal_reply(:unknown, :card), do: "That card is not known to Fermix; nothing ran."

  def refusal_reply(:wrong_origin, :card),
    do: "Answer it from the chat Fermix sent it to; nothing ran."

  def refusal_reply(:expired, :card), do: "That card expired; nothing ran."
  def refusal_reply({:not_waiting, "starting"}, :card), do: "That follow-up is already starting."
  def refusal_reply({:not_waiting, "started"}, :card), do: "That follow-up already ran."
  def refusal_reply({:not_waiting, "skipped"}, :card), do: "That card was skipped; nothing ran."
  def refusal_reply({:not_waiting, "expired"}, :card), do: "That card expired; nothing ran."
  def refusal_reply({:not_waiting, "refused"}, :card), do: "That card was refused; nothing ran."

  def refusal_reply(:unknown, :prompt),
    do: "That prompt is not known to Fermix; nothing was approved."

  def refusal_reply(:wrong_origin, :prompt), do: "Answer it from the chat Fermix sent it to."
  def refusal_reply(:expired, :prompt), do: "That prompt expired; each run still asks first."
  def refusal_reply({:not_waiting, "approved"}, :prompt), do: "That prompt was already approved."
  def refusal_reply({:not_waiting, "denied"}, :prompt), do: "That prompt was already answered."

  def refusal_reply({:not_waiting, "expired"}, :prompt),
    do: "That prompt expired; each run still asks first."

  def refusal_reply(reason, :card) do
    Logger.error("Follow-up answer failed: #{inspect(reason)}")
    "Fermix could not read that card; nothing ran."
  end

  def refusal_reply(reason, :prompt) do
    Logger.error("Approval answer failed: #{inspect(reason)}")
    "Fermix could not read that prompt; nothing was approved."
  end

  @doc "Serves `request` on SQL module `sql` through the Repo the opts name."
  @spec repo_call(module(), tuple(), keyword()) :: term()
  def repo_call(sql, request, opts) when is_atom(sql) and is_tuple(request) and is_list(opts) do
    repo_opts =
      [server: Keyword.get(opts, :repo, Repo)] ++ Keyword.take(opts, [:timeout, :on_timeout])

    Repo.cues_call(sql, request, repo_opts)
  end

  @doc "The time `opts[:now]` names, else now."
  @spec now(keyword()) :: DateTime.t()
  def now(opts) when is_list(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
end
