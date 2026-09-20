defmodule FermixCore.ComputerUse.Notice do
  @moduledoc """
  One sentence from a computer-use session to the conversation it belongs to
  (M42 slice 5 §4).

  A session normally speaks only through tool results: the model asks, the tool
  answers. The on-screen indicator's Stop breaks that, because the person acted
  on the machine and not in the chat — and after a stop there is no session left
  for a later tool result to answer from. So this is the one place a session
  writes to the conversation itself.

  **Where the conversation is, is not configured.** A session's registry key IS
  the conversation's delivery triple (`{platform, destination, thread_scope}`),
  the same shape `Temporal.Followup` builds a reminder's context from, so the
  answer is derived from the work that is being stopped rather than from an
  operator value nobody set (the "where is the owner's inbox" lesson). The thread
  option comes from `Temporal.Delivery.thread_opts/1`, which owns the one table
  of platform thread spellings; there is no second copy here.

  Best effort and bounded: one attempt, a short watchdog, and an `{:error,
  reason}` the caller logs. A notice that could not be delivered must never hold
  up the teardown that gives the person their machine back, and it is never
  retried — a stop announced a minute late, into a conversation that has moved
  on, is worse than one the log records.
  """

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Temporal.Delivery, as: TemporalDelivery

  # Well under the session's own 10 s shutdown budget, and this runs before the
  # teardown rather than inside it.
  @deliver_budget_ms 3_000

  @doc """
  Deliver `text` to the conversation `conversation_key` names.

  `opts` carries `ChannelSend`'s own seams (`:adapter`, `:channels`), so this is
  testable without a channel. A key that is not a delivery triple — a CLI run, a
  direct caller, a session started outside the registry — has no conversation to
  answer into and says so.
  """
  @spec deliver(term(), String.t(), keyword()) :: :ok | {:error, term()}
  def deliver(conversation_key, text, opts \\ []) when is_binary(text) and is_list(opts) do
    with {:ok, platform, destination, scope} <- coordinates(conversation_key),
         {:ok, send_opts} <- thread_opts(platform, scope) do
      send_once(platform, destination, text, send_opts, opts)
    end
  end

  defp coordinates({platform, destination, scope})
       when (is_binary(platform) or is_atom(platform)) and
              (is_binary(destination) or is_atom(destination) or is_integer(destination)) do
    {:ok, to_string(platform), to_string(destination), scope}
  end

  defp coordinates(key), do: {:error, {:no_conversation, key}}

  # The §11.1 table of platform thread spellings, asked of the module that owns
  # it. A platform it does not know is not an error worth a second table here:
  # the notice simply cannot be threaded, and that is what the caller logs.
  defp thread_opts(platform, scope) do
    case TemporalDelivery.thread_opts(%{
           delivery_platform: platform,
           delivery_thread_scope: thread_scope(scope)
         }) do
      {:ok, send_opts} -> {:ok, send_opts}
      {:error, reason} -> {:error, reason}
    end
  end

  defp thread_scope(:root), do: "root"
  defp thread_scope(scope) when is_binary(scope) and scope != "", do: scope
  defp thread_scope(scope) when is_integer(scope), do: Integer.to_string(scope)
  defp thread_scope(_absent), do: "root"

  defp send_once(platform, destination, text, send_opts, opts) do
    @deliver_budget_ms
    |> ChannelSend.with_timeout(fn ->
      ChannelSend.send(
        platform,
        destination,
        text,
        send_opts,
        Keyword.put(opts, :delivery_max_attempts, 1)
      )
    end)
    |> normalize()
  end

  defp normalize(:ok), do: :ok
  defp normalize({:error, reason}), do: {:error, reason}
end
