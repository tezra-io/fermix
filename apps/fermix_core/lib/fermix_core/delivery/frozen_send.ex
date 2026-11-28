defmodule FermixCore.Delivery.FrozenSend do
  @moduledoc """
  One bounded send of a run's message to the destination its row froze when
  the run was admitted (`platform`, `destination`, `thread`, `send_opts`),
  shared by every run kind that freezes its destination this way: a coding
  run's outcome (`Harness.Delivery`) and a phone call's report
  (`PhoneCalls.Delivery`). The watchdog, the single attempt and the mapping of
  the frozen thread and send options to a channel's options are one rule
  here, over the generic `Delivery.ChannelSend` primitive.
  """

  alias FermixCore.Delivery.ChannelSend

  @doc """
  Makes ONE send of `text` to `row`'s frozen destination under the watchdog
  `opts[:timeout_ms]` (required: each run kind states its own bound), never
  retried. `opts[:link_previews]` `false` asks the channel to fetch no preview
  of a link in `text`, as a cue run's message does. The rest of `opts` goes
  to `ChannelSend.send/5`.
  """
  @spec send_text(map(), String.t(), keyword()) :: {:ok, :sent} | {:error, term()}
  def send_text(row, text, opts) when is_map(row) and is_binary(text) and is_list(opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    {previews, opts} = Keyword.pop(opts, :link_previews)

    send_opts =
      if previews == false,
        do: send_opts(row) ++ [link_previews: false],
        else: send_opts(row)

    result =
      ChannelSend.with_timeout(timeout_ms, fn ->
        ChannelSend.send(
          Map.get(row, :platform) || "",
          Map.get(row, :destination) || "",
          text,
          send_opts,
          Keyword.put(opts, :delivery_max_attempts, 1)
        )
      end)

    case result do
      :ok -> {:ok, :sent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A channel's send options for `row`'s frozen thread and send options."
  @spec send_opts(map()) :: keyword()
  def send_opts(row) when is_map(row) do
    []
    |> put_thread(Map.get(row, :thread))
    |> merge_send_opts(Map.get(row, :send_opts))
  end

  defp put_thread(opts, thread) when is_binary(thread) and thread != "" do
    Keyword.merge(opts, thread_ts: thread, message_thread_id: thread)
  end

  defp put_thread(opts, _thread), do: opts

  defp merge_send_opts(opts, map) when is_map(map) do
    Enum.reduce(map, opts, fn {key, value}, acc ->
      case send_opt_key(key) do
        nil -> acc
        atom_key -> Keyword.put(acc, atom_key, value)
      end
    end)
  end

  defp merge_send_opts(opts, _map), do: opts

  # A closed allowlist: `send_opts` is Fermix-generated at admission, but map its
  # string keys through a fixed table so a malformed row can never trigger atom
  # exhaustion via `String.to_atom/1`.
  defp send_opt_key("thread_ts"), do: :thread_ts
  defp send_opt_key("message_thread_id"), do: :message_thread_id
  defp send_opt_key("reply_to"), do: :reply_to
  defp send_opt_key("req_options"), do: :req_options
  defp send_opt_key(_other), do: nil
end
