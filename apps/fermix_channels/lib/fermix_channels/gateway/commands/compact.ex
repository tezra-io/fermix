defmodule FermixChannels.Gateway.Commands.Compact do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  require Logger

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Providers.Failover
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.Selection
  alias FermixCore.Telemetry

  @impl true
  def name, do: "compact"

  @impl true
  def aliases, do: []

  @impl true
  def description, do: "Compact this conversation history now."

  @impl true
  def authorize(message, metadata, context),
    do: Authorization.owner_only(message, metadata, context)

  @impl true
  def execute(_message, reply_fn, context) do
    conversation_key = Map.fetch!(context, :conversation_key)
    conversation_store = Map.fetch!(context, :conversation_store)

    %{messages: history, version: history_version} =
      ConversationStore.get_history_snapshot(conversation_key, server: conversation_store)

    before_tokens = Compactor.estimate_tokens(history)

    case routes_from_context(context) do
      {:ok, routes} ->
        routes
        |> compaction_routes(before_tokens)
        |> run_compaction(history, context, conversation_key)
        |> handle_result(%{
          reply_fn: reply_fn,
          conversation_key: conversation_key,
          conversation_store: conversation_store,
          context: context,
          before_tokens: before_tokens,
          history_version: history_version
        })

      {:error, reason} ->
        Logger.error("forced compaction route selection failed: #{inspect(reason)}")
        reply_fn.({:text, "Compaction failed: #{inspect(reason)}."})
        {:error, reason}
    end
  end

  # Same primary/fallback chain and shared executor as auto-compaction (§7).
  defp run_compaction(routes, history, context, conversation_key) do
    attempt = fn {route_key, adapter_opts} ->
      # Route opts may carry a pre-bound :adapter (the AgentLoop.bind_route
      # seam); unwrap Compactor's tag so the shared executor classifies the
      # real provider reason.
      {route_adapter, adapter_opts} = Keyword.pop(adapter_opts, :adapter)

      result =
        Compactor.compact(history,
          enabled: true,
          token_budget: forced_compact_budget(context, {route_key, adapter_opts}),
          route: {route_key, adapter_opts},
          adapter: route_adapter,
          context: compaction_context(conversation_key, context)
        )

      case result do
        {:error, {:compaction_failed, reason}} -> {:error, reason}
        other -> other
      end
    end

    Telemetry.timed_us(fn ->
      Failover.run_chain(routes, attempt, telemetry: %{agent: "main", surface: :compact_command})
    end)
  end

  defp handle_result({{:ok, %{messages: compacted, compacted?: true}}, duration_us}, run) do
    after_tokens = Compactor.estimate_tokens(compacted)

    case ConversationStore.replace_history(run.conversation_key, compacted,
           server: run.conversation_store,
           agent_id: Map.get(run.context, :memory_agent_id, "main"),
           owner_id: Map.get(run.context, :memory_owner_id, "default"),
           expected_version: run.history_version
         ) do
      :ok ->
        emit_forced_compaction(
          run.conversation_key,
          run.before_tokens,
          after_tokens,
          duration_us
        )

        run.reply_fn.(
          {:text,
           "Compacted: #{format_tokens(run.before_tokens)} -> #{format_tokens(after_tokens)} tokens."}
        )

      {:error, :stale_history} ->
        run.reply_fn.({:text, "Conversation changed while compacting; run /compact again."})
    end

    :ok
  end

  defp handle_result({{:ok, %{compacted?: false}}, _duration_us}, run) do
    run.reply_fn.({:text, "Nothing to compact (#{format_tokens(run.before_tokens)} tokens)."})
    :ok
  end

  defp handle_result({{:error, reason}, _duration_us}, run) do
    Logger.error("forced compaction failed: #{inspect(reason)}")
    run.reply_fn.({:text, "Compaction failed: #{inspect(reason)}."})
    {:error, reason}
  end

  defp emit_forced_compaction(conversation_key, before_tokens, after_tokens, duration_us) do
    :telemetry.execute(
      [:fermix, :compaction, :forced],
      %{before_tokens: before_tokens, after_tokens: after_tokens, duration_us: duration_us},
      %{conversation_key: conversation_key}
    )
  end

  defp routes_from_context(%{route: {_route_key, _adapter_opts} = route}), do: {:ok, [route]}
  defp routes_from_context(_context), do: Selection.ordered_routes()

  # Skip-not-clamp (§7): the lead route always stays; a fallback whose
  # context window cannot fit the prompt is excluded, never clamped to.
  defp compaction_routes([lead | rest], prompt_tokens) do
    [
      lead
      | Enum.filter(rest, fn {route_key, _opts} ->
          ModelCatalog.context_window_for(route_key.provider, route_key.model) >= prompt_tokens
        end)
    ]
  end

  defp forced_compact_budget(context, {route_key, _adapter_opts}) do
    context_window =
      Map.get(context, :context_window) ||
        ModelCatalog.context_window_for(route_key.provider, route_key.model)

    trunc(context_window * 0.5)
  end

  defp compaction_context(conversation_key, context) do
    %{
      conversation_key: conversation_key,
      memory_repo: Map.get(context, :memory_repo),
      memory_agent_id: Map.get(context, :memory_agent_id, "main"),
      memory_owner_id: Map.get(context, :memory_owner_id, "default")
    }
  end

  defp format_tokens(tokens) when is_integer(tokens) do
    tokens
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
