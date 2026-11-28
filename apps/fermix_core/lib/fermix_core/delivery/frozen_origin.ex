defmodule FermixCore.Delivery.FrozenOrigin do
  @moduledoc """
  Where a run's result goes, frozen when the run starts (design §9.1, M29
  §17.4), for every run kind that outlives the turn that started it: a coding
  run (`Harness`) and a phone call (`PhoneCalls.Delivery`). A chat turn derives
  `{platform, destination, thread}` from the conversation the same way
  `DeliveryDefaults` derives `origin_target`; a scheduled launch copies the
  parent job's already-resolved `delivery_mode`/`delivery_target` (never the
  synthetic cron key), splitting it into the three ledger columns. The
  snapshot is persisted on the run's row, so a later config edit can never
  retarget a run in flight; `Delivery.FrozenSend` makes the send to it.
  """

  alias FermixCore.Acp.Identity
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scope
  alias FermixCore.Text

  # The launching turn's excerpt is bounded on the row (M29 §17.4) and read from
  # the tail of the conversation, not its whole history.
  @reply_context_max 4_096
  @reply_context_scan 10

  @type t :: %{
          origin_kind: String.t(),
          delivery_mode: String.t(),
          platform: String.t() | nil,
          destination: String.t() | nil,
          thread: String.t() | nil,
          send_opts: map() | nil,
          parent_job_id: String.t() | nil,
          client_origin: map() | nil
        }

  @doc """
  Freezes the delivery snapshot for a run launched from `ctx`.

  `ctx.conversation_key` selects the origin: a `{:scheduled_job, job_id, _}` key
  copies the parent job's frozen delivery (fetched via `Jobs.Registry`, server
  from `ctx.memory_repo` or `opts[:registry_server]`); a `{channel, chat_id, _}`
  key derives an `origin`-mode chat snapshot. Any other key is unresolvable.

  A chat snapshot additionally freezes the **client origin** when the turn carries
  a client-presented identity (M29 §17.4) — see `client_origin/2`.
  """
  @spec resolve(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def resolve(ctx, opts \\ []) when is_map(ctx) and is_list(opts) do
    case Map.get(ctx, :conversation_key) do
      {:scheduled_job, job_id, _run_id} when is_binary(job_id) ->
        resolve_scheduled(job_id, ctx, opts)

      {channel, chat_id, thread_scope} when is_binary(channel) and is_binary(chat_id) ->
        {:ok, chat_snapshot(channel, chat_id, thread_scope, ctx, opts)}

      {channel, chat_id} when is_binary(channel) and is_binary(chat_id) ->
        {:ok, chat_snapshot(channel, chat_id, :root, ctx, opts)}

      other ->
        {:error, {:unresolvable_delivery_origin, other}}
    end
  end

  defp chat_snapshot(channel, chat_id, thread_scope, ctx, opts) do
    %{
      origin_kind: "chat",
      delivery_mode: "origin",
      platform: channel,
      destination: chat_id,
      thread: chat_thread(thread_scope),
      send_opts: nil,
      parent_job_id: nil,
      # The conversation key is rebuilt here rather than re-read from `ctx`, so the
      # excerpt read below always addresses a well-formed three-element key — the
      # same normalization the two-element clause above already applies.
      client_origin: client_origin({channel, chat_id, thread_scope}, ctx, opts)
    }
  end

  defp chat_thread(:root), do: nil
  defp chat_thread(scope), do: Scope.normalize_thread_scope(scope)

  # A CLIENT-OWNED origin (M29 §17.4). The ACP session that launched this run is
  # gone by the time it finishes, so freeze the three things the continuation
  # cannot recover from a dead session:
  #
  #   * `identity` — derived by the SAME `Identity.id_from_env/1` the Peer used at
  #     hello, so launch and hello can never disagree about whose run this is. It
  #     is what lets a continuation find credentials for a session id that no
  #     longer resolves.
  #   * `cwd` — the working directory the launching turn ran under, so the
  #     continuation turn reproduces it instead of falling to the sandbox default.
  #   * `reply_context` — a bounded, OPAQUE excerpt of the launching user turn.
  #     Fermix stores bytes and re-presents them; it never parses them, so no
  #     Fermix-side parser of a client's prompt format is created (§13 stands).
  #     History alone is not enough: pre-flight auto-compaction can summarize a
  #     high-entropy reply anchor away in the minutes this feature exists to span.
  #
  # No derivable identity ⇒ not a client-owned origin, which is the ordinary
  # answer on every framework-delivered channel: nothing but `Identity.to_env/1`
  # ever populates `session_env` (§17.1), and by the drop rule (§17.2) a key that
  # will not derive is not carried at all.
  defp client_origin(key, ctx, opts) do
    case Identity.id_from_env(Map.get(ctx, :session_env) || %{}) do
      {:ok, id} -> frozen_origin(id, key, ctx, opts)
      {:error, _no_identity} -> nil
    end
  end

  defp frozen_origin(id, key, ctx, opts) do
    %{
      "identity" => id,
      "cwd" => Map.get(ctx, :cwd),
      "reply_context" => reply_context(key, ctx, opts)
    }
  end

  defp reply_context(key, ctx, opts) do
    server =
      Keyword.get(opts, :conversation_store) ||
        Map.get(ctx, :conversation_store, ConversationStore)

    key
    |> ConversationStore.get_history(server: server, limit: @reply_context_scan)
    |> last_user_text()
    |> bound_context()
  end

  defp last_user_text(history) when is_list(history) do
    history |> Enum.reverse() |> Enum.find_value(&user_text/1)
  end

  defp user_text(%{role: "user", content: content}) when is_binary(content) and content != "",
    do: content

  defp user_text(_message), do: nil

  # A byte cut can land inside a multibyte codepoint, and this value is
  # `Jason.encode!`d onto the ledger row: invalid UTF-8 would raise there and
  # take the launch down, so the cut is the engine's one cut, never inside a
  # codepoint (`FermixCore.Text`).
  defp bound_context(nil), do: nil
  defp bound_context(text), do: Text.truncate_utf8(text, @reply_context_max)

  defp resolve_scheduled(job_id, ctx, opts) do
    server = Keyword.get(opts, :registry_server, Map.get(ctx, :memory_repo, Repo))

    case JobsRegistry.get_job(job_id, server: server) do
      {:ok, job} -> {:ok, scheduled_snapshot(job)}
      {:error, reason} -> {:error, {:parent_job_lookup_failed, reason}}
    end
  end

  defp scheduled_snapshot(job) do
    target = job.delivery_target || %{}

    %{
      origin_kind: "scheduled",
      delivery_mode: job.delivery_mode,
      platform: target_field(target, ["platform", "channel"]),
      # Same key precedence as `Jobs.Delivery.normalize_target` so both rails
      # resolve one identical destination from the same frozen job target.
      destination:
        target_field(target, ["chat_id", "reply_target", "target", "recipient", "channel_id"]),
      thread: target_field(target, ["thread_ts", "message_thread_id"]),
      send_opts: target_extra_opts(target),
      parent_job_id: job.id,
      # A scheduled origin has no client session to belong to, by construction.
      client_origin: nil
    }
  end

  defp target_field(target, keys) do
    Enum.find_value(keys, fn key -> target_string(Map.get(target, key)) end)
  end

  defp target_string(value) when is_binary(value) and value != "", do: value
  defp target_string(_value), do: nil

  defp target_extra_opts(target) do
    extras =
      target
      |> Map.take(["reply_to", "req_options"])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(extras) == 0, do: nil, else: extras
  end
end
