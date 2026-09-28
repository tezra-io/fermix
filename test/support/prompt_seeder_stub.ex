defmodule FermixTestSupport.PromptSeederStub do
  @moduledoc false
  # The prompt seeder the suite runs by default (`config/test.exs`): it seeds
  # nothing and rebuilds nothing, so a save in a test with no memory repo behind
  # it still commits and writes no prompt file into the suite's home. Tests that
  # prove seeding put `FermixCore.Prompt.SetupSeeder` back for their own scope.

  @spec seed(map(), keyword()) :: {:ok, []}
  def seed(_personalization, _opts \\ []), do: {:ok, []}

  @spec rebuild_user_document(keyword()) :: {:ok, %{user: nil, memory: nil}}
  def rebuild_user_document(_opts \\ []), do: {:ok, %{user: nil, memory: nil}}
end
