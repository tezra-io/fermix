defmodule FermixTestSupport.MachineFactsStub do
  @moduledoc false
  # The machine facts the suite sees (`config/test.exs`): fixed, whatever host
  # runs it. A test that needs a fact to be unavailable overrides it through
  # `Application.put_env(:fermix_core, :machine_facts_answers, full_name: :error)`
  # and restores the key.
  @behaviour FermixCore.Setup.MachineFacts

  @answers [timezone: {:ok, "America/New_York"}, full_name: {:ok, "Test Operator"}]

  @impl true
  def timezone, do: answer(:timezone)

  @impl true
  def full_name, do: answer(:full_name)

  defp answer(key) do
    :fermix_core
    |> Application.get_env(:machine_facts_answers, [])
    |> Keyword.get(key, Keyword.fetch!(@answers, key))
  end
end
