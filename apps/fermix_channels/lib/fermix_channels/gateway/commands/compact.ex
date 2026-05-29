defmodule FermixChannels.Gateway.Commands.Compact do
  @moduledoc false

  @behaviour FermixChannels.Gateway.Command

  require Logger

  alias FermixChannels.Gateway.Commands.Authorization
  alias FermixCore.Memory.Compactor
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Providers.ModelCatalog
  alias FermixCore.Providers.RouteResolver
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
    route = route_from_context(context)

    opts =
      [
        enabled: true,
        token_budget: forced_compact_budget(context, route),
        route: route,
        context: compaction_context(conversation_key, context)
      ]

    {compaction_result, duration_us} =
      Telemetry.timed_us(fn -> Compactor.compact(history, opts) end)

    case compaction_result do
      {:ok, %{messages: compacted, compacted?: true}} ->
        after_tokens = Compactor.estimate_tokens(compacted)

        case ConversationStore.replace_history(conversation_key, compacted,
               server: conversation_store,
               agent_id: Map.get(context, :memory_agent_id, "main"),
               owner_id: Map.get(context, :memory_owner_id, "default"),
               expected_version: history_version
             ) do
          :ok ->
            emit_forced_compaction(conversation_key, before_tokens, after_tokens, duration_us)

            reply_fn.(
              {:text,
               "Compacted: #{format_tokens(before_tokens)} -> #{format_tokens(after_tokens)} tokens."}
            )

          {:error, :stale_history} ->
            reply_fn.({:text, "Conversation changed while compacting; run /compact again."})
        end

        :ok

      {:ok, %{compacted?: false}} ->
        reply_fn.({:text, "Nothing to compact (#{format_tokens(before_tokens)} tokens)."})
        :ok

      {:error, reason} ->
        Logger.error("forced compaction failed: #{inspect(reason)}")
        reply_fn.({:text, "Compaction failed: #{inspect(reason)}."})
        {:error, reason}
    end
  end

  defp emit_forced_compaction(conversation_key, before_tokens, after_tokens, duration_us) do
    :telemetry.execute(
      [:fermix, :compaction, :forced],
      %{before_tokens: before_tokens, after_tokens: after_tokens, duration_us: duration_us},
      %{conversation_key: conversation_key}
    )
  end

  defp route_from_context(%{route: {_route_key, _adapter_opts} = route}), do: route
  defp route_from_context(_context), do: RouteResolver.resolve!()

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
