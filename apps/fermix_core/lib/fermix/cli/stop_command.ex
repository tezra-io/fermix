defmodule Fermix.CLI.StopCommand do
  @moduledoc """
  `fermix stop` — stop the installed OS service.

  Mirrors `Fermix.CLI.StartCommand` but calls `Service.stop/1`. If no
  unit is installed we abort non-zero with a clear pointer at
  `fermix service install` rather than silently returning success on a
  no-op stop.
  """

  alias Fermix.CLI.Service
  alias Fermix.CLI.ServiceCommand

  @switches [user: :boolean, system: :boolean]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case ServiceCommand.parse_scope(argv, @switches) do
      {:ok, scope} -> dispatch(scope)
      {:error, reason} -> abort(reason)
    end
  end

  defp dispatch(scope) do
    cond do
      Service.installed?(scope) ->
        ServiceCommand.run_action(&Service.stop/1, scope, "stopped", "fermix stop")

      Service.installed?(other_scope(scope)) ->
        abort(
          "no #{scope}-scope unit installed; the #{other_scope(scope)}-scope unit is. " <>
            "Use `fermix stop --#{other_scope(scope)}`."
        )

      true ->
        abort("no service installed. Nothing to stop.")
    end
  end

  defp other_scope(:user), do: :system
  defp other_scope(:system), do: :user

  defp abort(message) do
    IO.puts(:stderr, "fermix stop: #{message}")
    1
  end
end
