defmodule FermixCore.PhoneCalls.Delivery do
  @moduledoc """
  Where a call's report goes and the attempts that take it there (M94 §04,
  §09), the coding run's rules with no second outbox.

    * **The destination** is frozen when the tool runs (`snapshot/2`): a chat
      turn's through `Harness.Delivery.resolve_snapshot/2`, exactly as a coding
      run's; a voice turn's is the owner's durable private inbox
      (`Delivery.OwnerInbox.resolve/1`), resolved before admission, and the
      call is refused if there is none. A client-owned origin (an ACP session,
      whose turn ends with it) is refused: it has no framework path to report
      on. The snapshot rides the ledger row, so a later config edit never
      retargets a call.
    * **The hand-off** (`hand_off/2`) runs once the terminal row is written,
      outside the Manager's process, while the terminal write's lease keeps the
      `PhoneCalls.DeliveryWorker` off the row: a chat origin re-enters its
      conversation (`PhoneCalls.Continuation`); otherwise, or after a failed
      dispatch, one inline send (`deliver/2`). A send that fails counts as the
      first of `Limits.max_report_delivery_attempts/0` and leaves the row
      pending for the worker.
    * **One send** (`deliver/2`) is `Harness.Delivery.send_text/3` with the
      composed report (`PhoneCalls.Report.compose/1`), the coding run's bounded
      single attempt. A resend after a failed attempt says the earlier one may
      have arrived, since a timed-out send can still have been delivered.

  Nothing here ever dials: retrying a report never retries its call.
  """

  require Logger

  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Harness.Delivery, as: HarnessDelivery
  alias FermixCore.PhoneCalls.Continuation
  alias FermixCore.PhoneCalls.DeliveryWorker
  alias FermixCore.PhoneCalls.Ledger
  alias FermixCore.PhoneCalls.Report

  @resent_label "(Sent again: an earlier attempt to send this report may or may not have arrived.)"
  @error_max 500

  @type snapshot :: %{
          origin_kind: String.t(),
          delivery_mode: String.t(),
          platform: String.t(),
          destination: String.t(),
          thread: String.t() | nil,
          send_opts: map() | nil,
          origin_conversation: [String.t()] | nil
        }

  @doc """
  Freezes where the call's report goes, at tool-execute time. `voice?` says
  the request came from a live voice turn. Seams: `opts[:owner_inbox]` (the
  `OwnerInbox.resolve/1` options) and the coding run's own
  `resolve_snapshot/2` options.
  """
  @spec snapshot(map(), boolean(), keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(context, voice?, opts \\ []) when is_map(context) and is_boolean(voice?) do
    if voice?, do: owner_inbox_snapshot(opts), else: chat_snapshot(context, opts)
  end

  defp owner_inbox_snapshot(opts) do
    case OwnerInbox.resolve(Keyword.get(opts, :owner_inbox, [])) do
      {:ok, inbox} ->
        {:ok,
         %{
           origin_kind: "voice",
           delivery_mode: "channel",
           platform: inbox.platform,
           destination: inbox.destination,
           thread: nil,
           send_opts: nil,
           origin_conversation: nil
         }}

      :no_delivery_target ->
        {:error, :no_owner_inbox}
    end
  end

  defp chat_snapshot(context, opts) do
    case HarnessDelivery.resolve_snapshot(context, opts) do
      {:ok, %{origin_kind: "chat", client_origin: nil} = snapshot} ->
        {:ok, chat_fields(snapshot, Map.get(context, :conversation_key))}

      {:ok, %{origin_kind: "chat"}} ->
        {:error, :client_owned_origin}

      {:ok, %{origin_kind: kind}} ->
        {:error, {:unsupported_origin, kind}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chat_fields(snapshot, key) do
    %{
      origin_kind: "chat",
      delivery_mode: snapshot.delivery_mode,
      platform: snapshot.platform,
      destination: snapshot.destination,
      thread: snapshot.thread,
      send_opts: snapshot.send_opts,
      origin_conversation: conversation(key)
    }
  end

  defp conversation({channel, chat_id, :root}), do: [channel, chat_id, "root"]

  defp conversation({channel, chat_id, thread}) when is_binary(thread),
    do: [channel, chat_id, thread]

  defp conversation({channel, chat_id}), do: [channel, chat_id, "root"]
  defp conversation(_other), do: nil

  @doc """
  One bounded send of `row`'s report to its frozen destination. Answers
  `{:ok, :sent}` or the send's error for the caller to record.
  """
  @spec deliver(map(), keyword()) :: {:ok, :sent} | {:error, term()}
  def deliver(row, opts \\ []) when is_map(row) and is_list(opts),
    do: HarnessDelivery.send_text(row, text(row), opts)

  defp text(row) do
    if (Map.get(row, :delivery_attempts) || 0) > 0,
      do: @resent_label <> "\n" <> Report.compose(row),
      else: Report.compose(row)
  end

  @doc """
  The terminal hand-off (see the moduledoc). `opts`: `:repo` (required), `:now_fn`,
  `:delivery_opts` (ChannelSend's) and `:continuation_opts` (the dispatcher
  seam). Always `:ok`: every outcome is recorded on the row or logged.
  """
  @spec hand_off(map(), keyword()) :: :ok
  def hand_off(%{id: id} = row, opts) when is_binary(id) and is_list(opts) do
    case continuation(row, opts) do
      {:ok, dispatcher} -> continue_or_send(row, dispatcher, opts)
      :none -> send_inline(row, opts)
    end
  end

  defp continuation(row, opts) do
    if Continuation.continuable?(row),
      do: Continuation.dispatcher(Keyword.get(opts, :continuation_opts, [])),
      else: :none
  end

  defp continue_or_send(row, dispatcher, opts) do
    case Continuation.dispatch(dispatcher, row) do
      :ok ->
        Logger.info("phone call #{row.id} reported into its conversation")
        mark(row, %{report_status: "written", delivered_at: now(opts)}, opts)

      {:error, reason} ->
        Logger.warning(
          "phone call #{row.id} continuation failed: #{inspect(reason)}; sending text"
        )

        send_inline(row, opts)
    end
  end

  defp send_inline(row, opts) do
    case deliver(row, Keyword.get(opts, :delivery_opts, [])) do
      {:ok, :sent} -> mark(row, %{report_status: "written", delivered_at: now(opts)}, opts)
      {:error, reason} -> mark(row, first_failure(reason, opts), opts)
    end
  end

  defp first_failure(reason, opts) do
    %{
      delivery_attempts: 1,
      next_delivery_at: DateTime.add(now(opts), DeliveryWorker.backoff_ms(1), :millisecond),
      last_delivery_error: bounded_error(reason)
    }
  end

  defp mark(row, fields, opts) do
    case Ledger.mark_report(row.id, fields, server: Keyword.fetch!(opts, :repo)) do
      {:ok, _row} ->
        :ok

      {:error, reason} ->
        Logger.warning("phone call #{row.id} report state not recorded: #{inspect(reason)}")
    end
  end

  defp now(opts), do: Keyword.get(opts, :now_fn, &DateTime.utc_now/0).()

  @doc "The bounded text an error is recorded under."
  @spec bounded_error(term()) :: String.t()
  def bounded_error(reason), do: reason |> inspect() |> String.slice(0, @error_max)
end
