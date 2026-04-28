defmodule Fermix.CLI.RestartCommand do
  @moduledoc """
  `fermix restart` — restart the installed OS service.

  Refuses on uninstalled hosts (no implicit install) and surfaces
  scope mismatches the same way `start`/`stop` do, so `--user` against
  a `--system` install fails with a clear pointer instead of looking
  like a no-op restart.
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
        ServiceCommand.run_action(&Service.restart/1, scope, "restarted", "fermix restart")

      Service.installed?(other_scope(scope)) ->
        abort(
          "no #{scope}-scope unit installed; the #{other_scope(scope)}-scope unit is. " <>
            "Use `fermix restart --#{other_scope(scope)}`."
        )

      true ->
        abort("no service installed. Run `fermix service install` first.")
    end
  end

  defp other_scope(:user), do: :system
  defp other_scope(:system), do: :user

  defp abort(message) do
    IO.puts(:stderr, "fermix restart: #{message}")
    1
  end
end
