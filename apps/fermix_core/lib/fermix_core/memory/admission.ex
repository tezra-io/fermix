defmodule FermixCore.Memory.Admission do
  @moduledoc """
  Deterministic admission policy for extracted durable memory candidates.
  """

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Scope

  @valid_categories MapSet.new(
                      ~w(identity preference goal project environment instruction correction episode)
                    )
  @user_promoted_categories MapSet.new(~w(identity preference goal correction))
  @memory_promoted_categories MapSet.new(~w(project environment instruction correction))
  @direct_owner_categories MapSet.new(
                             ~w(identity preference goal project instruction correction episode)
                           )

  @type candidate :: %{
          required(:category) => String.t(),
          required(:key) => String.t(),
          required(:value) => String.t(),
          required(:scope_type) => String.t(),
          required(:confidence) => float(),
          optional(:promote_target) => String.t()
        }

  @type admitted_memory :: %{
          agent_id: String.t(),
          owner_id: String.t(),
          scope_type: String.t(),
          scope_id: String.t(),
          category: String.t(),
          key: String.t(),
          value: String.t(),
          confidence: float(),
          promote_target: String.t(),
          source_id: String.t() | nil,
          source_type: String.t() | nil,
          source_name: String.t() | nil,
          source_description: String.t() | nil,
          session_id: String.t() | nil,
          run_id: String.t() | nil
        }

  @type result :: %{
          admitted: [admitted_memory()],
          rebuild?: boolean(),
          corrective?: boolean()
        }

  @spec apply([candidate()], keyword()) :: result()
  def apply(candidates, opts) when is_list(candidates) and is_list(opts) do
    ctx = admission_context(opts)

    candidates
    |> Enum.reduce(%{}, &admit_candidate(&1, &2, ctx))
    |> Map.values()
    |> Enum.sort_by(& &1.order)
    |> Enum.map(&Map.delete(&1, :order))
    |> build_result()
  end

  @spec prompt_target(map()) :: String.t()
  def prompt_target(%{category: category, scope_type: scope_type})
      when is_binary(category) and is_binary(scope_type) do
    prompt_target(category, scope_type)
  end

  @spec category_allowed?(String.t(), atom() | nil) :: boolean()
  def category_allowed?(category, source_trust) when is_binary(category) do
    MapSet.member?(@valid_categories, category) and trust_allows_category?(category, source_trust)
  end

  defp admission_context(opts) do
    %{
      agent_id: Keyword.fetch!(opts, :agent_id),
      owner_id: Keyword.fetch!(opts, :owner_id),
      conversation_key: normalize_conversation_key(Keyword.fetch!(opts, :conversation_key)),
      chat_mode: normalize_chat_mode(Keyword.get(opts, :chat_mode, :direct)),
      source_trust: Keyword.get(opts, :source_trust),
      existing_memories: Keyword.get(opts, :existing_memories, %{}),
      repo: Keyword.get(opts, :repo, Config.repo_server()),
      min_confidence: Keyword.get(opts, :min_confidence, Config.extraction_min_confidence()),
      source_id: Keyword.get(opts, :source_id),
      source_type: Keyword.get(opts, :source_type),
      source_name: Keyword.get(opts, :source_name),
      source_description: Keyword.get(opts, :source_description),
      session_id: Keyword.get(opts, :session_id),
      run_id: Keyword.get(opts, :run_id)
    }
  end

  defp admit_candidate(candidate, acc, ctx) do
    case normalize_candidate(candidate, ctx) do
      {:ok, normalized} ->
        dedupe_key =
          {normalized.agent_id, normalized.scope_type, normalized.scope_id, normalized.key}

        Map.put(acc, dedupe_key, normalized)

      :discard ->
        acc
    end
  end

  defp normalize_candidate(candidate, ctx) do
    with {:ok, category} <- fetch_candidate_string(candidate, :category),
         true <- MapSet.member?(@valid_categories, category),
         true <- trust_allows_category?(category, ctx.source_trust),
         {:ok, key} <- fetch_candidate_string(candidate, :key),
         {:ok, value} <- fetch_candidate_string(candidate, :value),
         confidence when confidence >= ctx.min_confidence <- fetch_confidence(candidate),
         candidate_scope_type <- resolve_scope_type(category, ctx.chat_mode, candidate),
         candidate_scope_id <- scope_id(candidate_scope_type, ctx),
         existing <- existing_memory(ctx, candidate_scope_type, candidate_scope_id, key, category),
         {scope_type, scope_id} <-
           admitted_scope(candidate_scope_type, candidate_scope_id, existing, category),
         final_category <- resolve_category(category, existing),
         promote_target <- prompt_target(final_category, scope_type),
         true <- changed?(existing, value, final_category, promote_target) do
      {:ok,
       %{
         order: System.unique_integer([:positive, :monotonic]),
         agent_id: ctx.agent_id,
         owner_id: ctx.owner_id,
         scope_type: scope_type,
         scope_id: scope_id,
         category: final_category,
         key: key,
         value: value,
         confidence: confidence,
         promote_target: promote_target,
         source_id: ctx.source_id,
         source_type: ctx.source_type,
         source_name: ctx.source_name,
         source_description: ctx.source_description,
         session_id: ctx.session_id,
         run_id: ctx.run_id,
         corrective?: category == "correction"
       }}
    else
      false -> :discard
      :discard -> :discard
      {:error, _reason} -> :discard
      _other -> :discard
    end
  end

  defp build_result(admitted) do
    %{
      admitted: Enum.map(admitted, &Map.drop(&1, [:corrective?])),
      rebuild?:
        Enum.any?(admitted, fn memory ->
          memory.corrective? or memory.promote_target != "none"
        end),
      corrective?: Enum.any?(admitted, & &1.corrective?)
    }
  end

  defp fetch_candidate_string(candidate, key) do
    case Map.get(candidate, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:blank, key}}
          trimmed -> {:ok, trimmed}
        end

      _other ->
        {:error, {:invalid, key}}
    end
  end

  defp fetch_confidence(%{confidence: value})
       when is_float(value) and value >= 0.0 and value <= 1.0,
       do: value

  defp fetch_confidence(%{confidence: value})
       when is_integer(value) and value >= 0 and value <= 1,
       do: value * 1.0

  defp fetch_confidence(_candidate), do: 0.0

  defp resolve_scope_type(category, :direct, candidate) do
    candidate_scope = Map.get(candidate, :scope_type, "conversation")

    cond do
      candidate_scope == "agent" or category == "environment" ->
        "agent"

      MapSet.member?(@direct_owner_categories, category) ->
        "owner"

      true ->
        "conversation"
    end
  end

  defp resolve_scope_type(category, :shared, candidate) do
    candidate_scope = Map.get(candidate, :scope_type, "conversation")

    if candidate_scope == "agent" or category == "environment" do
      "agent"
    else
      "conversation"
    end
  end

  defp resolve_category("correction", %{category: existing_category})
       when is_binary(existing_category),
       do: existing_category

  defp resolve_category(category, _existing), do: category

  # Audit F-09: explicit `:guest` callers cannot promote
  # instruction/correction candidates into durable memory. Those two
  # categories shape *future* agent behavior via the persisted prompt
  # files (`memory_md` / `user_md`); accepting them from non-operator
  # remote prompts is the path the audit called out. `:operator` and
  # `nil` (admission paths that don't carry trust info, e.g. internal
  # extractor runs) keep the full category surface — Admission's job
  # is to restrict an *explicit* low-trust source, not to second-guess
  # internal callers that never produced an unauthorised source.
  defp trust_allows_category?(category, :guest)
       when category in ["instruction", "correction"],
       do: false

  defp trust_allows_category?(_category, _trust), do: true

  defp prompt_target(category, "owner") do
    cond do
      MapSet.member?(@user_promoted_categories, category) -> "user_md"
      MapSet.member?(@memory_promoted_categories, category) -> "memory_md"
      true -> "none"
    end
  end

  defp prompt_target(category, "agent") do
    if MapSet.member?(@memory_promoted_categories, category), do: "memory_md", else: "none"
  end

  defp prompt_target(category, "conversation") do
    if MapSet.member?(@memory_promoted_categories, category) and category != "correction" do
      "memory_md"
    else
      "none"
    end
  end

  defp prompt_target(_category, "job"), do: "none"

  defp scope_id("owner", ctx), do: ctx.owner_id
  defp scope_id("agent", ctx), do: ctx.agent_id

  defp scope_id("conversation", ctx) do
    {channel, chat_id, thread_scope} = ctx.conversation_key
    Scope.conversation_scope_id(channel, chat_id, thread_scope)
  end

  defp existing_memory(ctx, scope_type, scope_id, key, "correction") do
    exact = exact_existing_memory(ctx, scope_type, scope_id, key)

    if prompt_backed_memory?(exact) do
      exact
    else
      prompt_backed_existing_memory(ctx, key) || exact
    end
  end

  defp existing_memory(ctx, scope_type, scope_id, key, _category) do
    exact_existing_memory(ctx, scope_type, scope_id, key)
  end

  defp exact_existing_memory(
         %{existing_memories: existing_memories, agent_id: agent_id},
         scope_type,
         scope_id,
         key
       )
       when map_size(existing_memories) > 0 do
    Map.get(existing_memories, {scope_type, scope_id, key}) ||
      Map.get(existing_memories, {scope_id, key}) ||
      Map.get(existing_memories, {agent_id, scope_type, scope_id, key})
  end

  defp exact_existing_memory(ctx, scope_type, scope_id, key) do
    case Repo.get_memory(
           %{
             agent_id: ctx.agent_id,
             owner_id: ctx.owner_id,
             scope_type: scope_type,
             scope_id: scope_id,
             key: key,
             archived?: false
           },
           server: ctx.repo
         ) do
      {:ok, memory} -> memory
      {:error, :not_found} -> nil
      {:error, :disabled} -> nil
      {:error, reason} -> raise "admission lookup failed: #{inspect(reason)}"
    end
  end

  defp prompt_backed_existing_memory(%{existing_memories: existing_memories} = ctx, key)
       when map_size(existing_memories) > 0 do
    existing_memories
    |> Map.values()
    |> Enum.filter(&memory_matches_key?(ctx, &1, key))
    |> Enum.find(&prompt_backed_memory?/1)
  end

  defp prompt_backed_existing_memory(ctx, key) do
    case Repo.get_memories(
           %{agent_id: ctx.agent_id, owner_id: ctx.owner_id, key: key, archived?: false},
           server: ctx.repo
         ) do
      {:ok, memories} -> Enum.find(memories, &prompt_backed_memory?/1)
      {:error, :disabled} -> nil
      {:error, reason} -> raise "admission prompt lookup failed: #{inspect(reason)}"
    end
  end

  defp memory_matches_key?(ctx, memory, key) do
    memory.key == key and memory.agent_id == ctx.agent_id and memory.owner_id == ctx.owner_id
  end

  defp prompt_backed_memory?(nil), do: false

  defp prompt_backed_memory?(memory) do
    prompt_target(memory) != "none"
  end

  defp admitted_scope(_scope_type, _scope_id, existing, "correction")
       when is_map(existing) and is_binary(existing.scope_type) and is_binary(existing.scope_id) do
    {existing.scope_type, existing.scope_id}
  end

  defp admitted_scope(scope_type, scope_id, _existing, _category), do: {scope_type, scope_id}

  defp changed?(nil, _value, _category, _promote_target), do: true

  defp changed?(existing, value, category, promote_target) do
    existing.value != value or existing.category != category or
      existing.promote_target != promote_target
  end

  defp normalize_conversation_key({:ok, {channel, chat_id, thread_scope}})
       when is_binary(channel) and is_binary(chat_id),
       do: {channel, chat_id, thread_scope}

  defp normalize_conversation_key({channel, chat_id, thread_scope})
       when is_binary(channel) and is_binary(chat_id),
       do: {channel, chat_id, thread_scope}

  defp normalize_conversation_key({channel, chat_id})
       when is_binary(channel) and is_binary(chat_id),
       do: {channel, chat_id, :root}

  defp normalize_chat_mode(:direct), do: :direct
  defp normalize_chat_mode(:shared), do: :shared
  defp normalize_chat_mode("direct"), do: :direct
  defp normalize_chat_mode("shared"), do: :shared

  defp normalize_chat_mode(value) do
    raise ArgumentError, "invalid chat_mode: #{inspect(value)}"
  end
end
