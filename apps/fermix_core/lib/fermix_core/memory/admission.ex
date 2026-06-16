defmodule FermixCore.Memory.Admission do
  @moduledoc """
  Category/scope policy for durable memory: which categories a source may
  promote, and which prompt file (USER.md / MEMORY.md) a row targets.
  """

  # General-assistant taxonomy. USER.md holds the owner's functional spine
  # (who they are, how they like things, what they care about, what they are
  # working toward); MEMORY.md holds durable working knowledge (`context`) and
  # behavior-shaping rules (`directive`).
  @user_promoted_categories MapSet.new(~w(identity preference interest goal))
  @memory_promoted_categories MapSet.new(~w(context directive))
  @valid_categories MapSet.union(@user_promoted_categories, @memory_promoted_categories)

  @spec prompt_target(map()) :: String.t()
  def prompt_target(%{category: category, scope_type: scope_type})
      when is_binary(category) and is_binary(scope_type) do
    prompt_target(category, scope_type)
  end

  @spec category_allowed?(String.t(), atom() | nil) :: boolean()
  def category_allowed?(category, source_trust) when is_binary(category) do
    MapSet.member?(@valid_categories, category) and trust_allows_category?(category, source_trust)
  end

  # Single source of truth for which categories the reviewer may add under each
  # target bucket. `:user` bucket == owner-scoped USER.md categories;
  # `:memory` bucket == agent-scoped MEMORY.md categories.
  @spec promotable_category?(:user | :memory, String.t()) :: boolean()
  def promotable_category?(:user, category) when is_binary(category) do
    MapSet.member?(@user_promoted_categories, category)
  end

  def promotable_category?(:memory, category) when is_binary(category) do
    MapSet.member?(@memory_promoted_categories, category)
  end

  # Audit F-09: explicit `:guest` callers cannot promote `directive` candidates
  # into durable memory. `directive` (the former instruction/correction
  # categories) shapes *future* agent behavior via the persisted prompt files;
  # accepting it from non-operator remote prompts is the path the audit called
  # out. `:operator` and `nil` keep the full category surface.
  defp trust_allows_category?("directive", :guest), do: false

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
    if MapSet.member?(@memory_promoted_categories, category) and category != "directive" do
      "memory_md"
    else
      "none"
    end
  end

  defp prompt_target(_category, "job"), do: "none"
end
