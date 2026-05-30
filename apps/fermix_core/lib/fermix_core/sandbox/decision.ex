defmodule FermixCore.Sandbox.Decision do
  @moduledoc """
  Emits sandbox decision telemetry.
  """

  @type decision :: :allow | {:deny, term()} | {:hardline, String.t()}

  @spec emit(decision(), map()) :: decision()
  def emit(decision, metadata) when is_map(metadata) do
    :telemetry.execute(
      [:fermix, :sandbox, :decision],
      %{count: 1},
      Map.merge(metadata, decision_metadata(decision))
    )

    decision
  end

  defp decision_metadata(:allow), do: %{decision: :allow}
  defp decision_metadata({:deny, reason}), do: %{decision: :deny, reason: reason}
  defp decision_metadata({:hardline, reason}), do: %{decision: :hardline, reason: reason}
end
