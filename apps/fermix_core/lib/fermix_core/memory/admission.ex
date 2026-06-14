defmodule FermixCore.Memory.Admission do
  @moduledoc """
  Category/scope policy for durable memory: which categories a source may
  promote, and which prompt file (USER.md / MEMORY.md) a row targets.
  """

  @valid_categories MapSet.new(
                      ~w(identity preference goal project environment instruction correction episode)
                    )
  @user_promoted_categories MapSet.new(~w(identity preference goal correction))
  @memory_promoted_categories MapSet.new(~w(project environment instruction correction))

  @spec prompt_target(map()) :: String.t()
  def prompt_target(%{category: category, scope_type: scope_type})
      when is_binary(category) and is_binary(scope_type) do
    prompt_target(category, scope_type)
  end

  @spec category_allowed?(String.t(), atom() | nil) :: boolean()
  def category_allowed?(category, source_trust) when is_binary(category) do
    MapSet.member?(@valid_categories, category) and trust_allows_category?(category, source_trust)
  end

  # Audit F-09: explicit `:guest` callers cannot promote instruction/correction
  # candidates into durable memory. Those two categories shape *future* agent
  # behavior via the persisted prompt files (`memory_md` / `user_md`); accepting
  # them from non-operator remote prompts is the path the audit called out.
  # `:operator` and `nil` keep the full category surface.
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
end
