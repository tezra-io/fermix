defmodule FermixCore.Jobs.MediaBridge do
  @moduledoc """
  The scheduled run's media reply path (M46 §7.1–§7.4).

  A scheduled run has no chat turn behind it, so `send_attachment` and
  `generate_image` used to find no `reply_fn` and refuse. This builds one, ONCE
  per run, from the run's captured job configuration: the destination comes from
  `Jobs.Delivery.resolve_target/1` — the same resolver the final text uses — and
  never from live registry state, the latest incoming chat, or a model-supplied
  recipient.

  The closure accepts `{:media, part}` and nothing else: the final text stays
  scheduler-owned and is delivered exactly once by `Jobs.Runner`'s finalization.
  It is bounded on three axes, each refusing before the adapter is touched: the
  run must still be active (a closure that leaked into a straggling process
  cannot send after the loop ended), the run gets at most 16 media requests
  including failed ones, and a send is bounded by the lesser of the configured
  delivery timeout and the run's remaining execution budget.
  """

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Jobs.Delivery
  alias FermixCore.Reply

  # Per-run ceiling on media requests, failed attempts included (§7.4). The
  # counter is per run, which is correct even with the runner's whole-loop
  # transient retry: that retry only re-runs when no tool has started.
  @max_sends 16

  @type unavailable ::
          {:delivery_mode, String.t()}
          | {:invalid_delivery_target, term()}
          | {:media_adapter_unsupported, term()}

  @type opt ::
          {:adapter, module() | nil}
          | {:channels, map() | keyword()}
          | {:delivery_opts, keyword()}
          | {:delivery_timeout_ms, non_neg_integer() | nil}
          | {:deadline_ms, integer() | nil}
          | {:active, :atomics.atomics_ref()}
          | {:sends, :atomics.atomics_ref()}
          | {:delivery_max_attempts, pos_integer()}
          | {:delivery_backoff_ms, non_neg_integer()}

  @doc """
  Resolves `job`'s media destination once and returns the run-scoped reply
  function plus the target it is bound to, or `{:unavailable, reason}` when this
  job has no media route.

  The target comes back so the caller can describe the destination (the
  scheduled prompt's attachment line) without resolving it a second time —
  resolve once, bind once.

  `opts` must carry `:active` and `:sends` — two `:atomics` refs the runner owns
  — plus the delivery injection (`:adapter`, `:channels`, `:delivery_opts`), the
  configured `:delivery_timeout_ms` and the run's `:deadline_ms` (monotonic
  milliseconds, or `nil` for an unbounded run).
  """
  @spec build(map(), map(), [opt()]) ::
          {:ok, Reply.reply_fn(), Delivery.target()} | {:unavailable, unavailable()}
  def build(job, run, opts) when is_map(job) and is_map(run) and is_list(opts) do
    with {:ok, target} <- resolve_target(job),
         :ok <- ensure_media_adapter(target.platform, opts) do
      {:ok, reply_fn(target, run, opts), target}
    end
  end

  @doc """
  A short sentence fragment naming why a run has no media route, for the
  scheduled prompt's attachment line. The prompt must say what is true.
  """
  @spec unavailable_reason(unavailable()) :: String.t()
  def unavailable_reason({:delivery_mode, mode}), do: "delivery mode is #{mode}"
  def unavailable_reason({:invalid_delivery_target, _reason}), do: "no valid delivery target"

  def unavailable_reason({:media_adapter_unsupported, _reason}),
    do: "the channel cannot send files"

  @doc "The per-run media request ceiling."
  @spec max_sends() :: pos_integer()
  def max_sends, do: @max_sends

  # --- Resolution ---------------------------------------------------------

  defp resolve_target(job) do
    case Map.get(job, :delivery_mode, "none") do
      mode when mode in ["origin", "channel"] -> channel_target(job)
      mode -> {:unavailable, {:delivery_mode, mode}}
    end
  end

  defp channel_target(job) do
    case Delivery.resolve_target(job) do
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:unavailable, {:invalid_delivery_target, reason}}
    end
  end

  defp ensure_media_adapter(platform, opts) do
    resolution =
      ChannelSend.resolve_adapter(platform,
        adapter: Keyword.get(opts, :adapter),
        channels: Keyword.get(opts, :channels, %{}),
        dispatch: :send_media
      )

    case resolution do
      {:ok, _adapter} -> :ok
      {:error, reason} -> {:unavailable, {:media_adapter_unsupported, reason}}
    end
  end

  # --- The closure --------------------------------------------------------

  # Everything the closure needs is captured here, at build time: the target, the
  # bounds, and the injected delivery dependencies. It holds no repo handle, no
  # runner pid, and no way to retarget.
  defp reply_fn(target, run, opts) do
    bound = %{
      platform: target.platform,
      destination: target.destination,
      send_opts: target.opts ++ proactive_delivery_opts(run, opts),
      channel_opts: channel_opts(opts),
      active: Keyword.fetch!(opts, :active),
      sends: Keyword.fetch!(opts, :sends),
      deadline_ms: Keyword.get(opts, :deadline_ms),
      delivery_timeout_ms: Keyword.get(opts, :delivery_timeout_ms)
    }

    fn
      {:media, part} when is_map(part) -> send_media(part, bound)
      other -> {:error, {:unsupported_job_reply, reply_kind(other)}}
    end
  end

  defp proactive_delivery_opts(run, opts) do
    opts
    |> Keyword.get(:delivery_opts, [])
    |> Keyword.put(:proactive_key, "job:#{run.id}")
  end

  defp channel_opts(opts) do
    [
      adapter: Keyword.get(opts, :adapter),
      channels: Keyword.get(opts, :channels, %{}),
      dispatch: :send_media
    ] ++ Keyword.take(opts, [:delivery_max_attempts, :delivery_backoff_ms])
  end

  defp reply_kind({:text, _text}), do: :text
  defp reply_kind({:react, _emoji}), do: :react
  defp reply_kind({:approval_prompt, _spec}), do: :approval_prompt
  defp reply_kind({:approval_prompt, _text, _token}), do: :approval_prompt
  defp reply_kind(_other), do: :unknown

  # --- Bounded send -------------------------------------------------------

  defp send_media(part, bound) do
    with :ok <- ensure_active(bound.active),
         {:ok, sequence} <- claim_send(bound.sends),
         {:ok, timeout_ms} <- send_timeout(bound) do
      dispatch(part, bound, sequence, timeout_ms)
    end
  end

  defp ensure_active(active) do
    if :atomics.get(active, 1) == 1, do: :ok, else: {:error, :job_not_active}
  end

  # Failed attempts count: the bound exists to stop a loop, and a loop that keeps
  # failing is exactly the case that must stop. The claimed number is also this
  # attachment's position in the run, which names it on the wire.
  defp claim_send(sends) do
    case :atomics.add_get(sends, 1, 1) do
      sequence when sequence > @max_sends -> {:error, :media_limit_reached}
      sequence -> {:ok, sequence}
    end
  end

  defp send_timeout(%{deadline_ms: deadline_ms, delivery_timeout_ms: configured_ms}) do
    [configured_ms, remaining_ms(deadline_ms)]
    |> Enum.reject(&is_nil/1)
    |> bounded_timeout()
  end

  # Neither a configured timeout nor a run deadline: `with_timeout/2` runs the
  # send inline when given 0, which is the unbounded case.
  defp bounded_timeout([]), do: {:ok, 0}

  defp bounded_timeout(candidates) do
    case Enum.min(candidates) do
      ms when ms > 0 -> {:ok, ms}
      _spent -> {:error, :job_deadline_exceeded}
    end
  end

  defp remaining_ms(nil), do: nil
  defp remaining_ms(deadline_ms), do: deadline_ms - System.monotonic_time(:millisecond)

  # `proactive_part_id` distinguishes this attachment from the run's other sends
  # (and from its final text) inside the run-scoped `proactive_key`. It is not
  # decoration: the mobile adapter refuses a proactive media send that carries a
  # key without one, and a shared key would collapse a run's attachments into a
  # single deduplicated timeline entry.
  defp dispatch(part, bound, sequence, timeout_ms) do
    send_opts = Keyword.put(bound.send_opts, :proactive_part_id, "media-#{sequence}")

    ChannelSend.with_timeout(timeout_ms, fn ->
      ChannelSend.send_media(
        bound.platform,
        bound.destination,
        part,
        send_opts,
        bound.channel_opts
      )
    end)
  end
end
