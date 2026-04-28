defmodule Fermix.CLI.StartCommand do
  @moduledoc """
  `fermix start` — start the installed OS service.

  No-op-with-error when no unit is installed; prints guidance pointing
  at `fermix service install` or `fermix run` and exits non-zero so
  scripted callers don't silently assume "started" against an
  uninstalled host.
  """

  alias Fermix.CLI.Service
  alias Fermix.CLI.ServiceCommand

  @switches [user: :boolean, system: :boolean]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv) do
    case ServiceCommand.parse_scope(argv, @switches) do
      {:ok, scope} -> dispatch(scope, &Service.start/1, "started")
      {:error, reason} -> abort(reason)
    end
  end

  defp dispatch(scope, action, past_tense) do
    cond do
      Service.installed?(scope) ->
        ServiceCommand.run_action(action, scope, past_tense, "fermix start")

      Service.installed?(other_scope(scope)) ->
        abort(
          "no #{scope}-scope unit installed; the #{other_scope(scope)}-scope unit is. " <>
            "Use `fermix start --#{other_scope(scope)}` or reinstall."
        )

      true ->
        abort(
          "no service installed. Run `fermix service install` first, " <>
            "or `fermix run` to run in the foreground."
        )
    end
  end

  defp other_scope(:user), do: :system
  defp other_scope(:system), do: :user

  defp abort(message) do
    IO.puts(:stderr, "fermix start: #{message}")
    1
  end
end
