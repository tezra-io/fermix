defmodule Fermix.CLI.StopCommand do
  @moduledoc """
  `fermix stop` — stop the installed OS service.

  Mirrors `Fermix.CLI.StartCommand` but calls `Service.stop/1`. If no
  unit is installed we abort non-zero with a clear pointer at
  `fermix service install` rather than silently returning success on a
  no-op stop.
  """

  alias Fermix.CLI.HomeOwner
  alias Fermix.CLI.Service
  alias Fermix.CLI.ServiceCommand
  alias FermixCore.BuildInfo

  @switches [user: :boolean, system: :boolean]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    build_info = Keyword.get(deps, :build_info, BuildInfo)
    service = Keyword.get(deps, :service, Service)
    home_owner = Keyword.get(deps, :home_owner, HomeOwner)

    cond do
      # This binary is the app engine: the existing refusal, unchanged.
      build_info.app_engine?() ->
        abort(app_managed_message())

      # A formula binary pointed at an app-managed home. The predicate asks
      # about the home, never about the disk, so a machine with no app answers
      # false here and every verb behaves exactly as it did.
      home_owner.app_managed?(Keyword.take(deps, [:hello, :marker?, :socket_path])) ->
        abort(HomeOwner.refusal_sentence("fermix stop"))

      true ->
        parse_and_dispatch(argv, service)
    end
  end

  defp parse_and_dispatch(argv, service) do
    case ServiceCommand.parse_scope(argv, @switches) do
      {:ok, scope} -> dispatch(scope, service)
      {:error, reason} -> abort(reason)
    end
  end

  defp dispatch(scope, service) do
    cond do
      service.installed?(scope) ->
        ServiceCommand.run_action(
          fn selected_scope -> service.stop(selected_scope) end,
          scope,
          "stopped",
          "fermix stop"
        )

      service.installed?(other_scope(scope)) ->
        abort(
          "no #{scope}-scope unit installed; the #{other_scope(scope)}-scope unit is. " <>
            "Use `fermix stop --#{other_scope(scope)}`."
        )

      true ->
        abort("no service installed. Nothing to stop.")
    end
  end

  defp app_managed_message do
    "this engine is managed by Fermix.app. Use Fermix.app background service controls."
  end

  defp other_scope(:user), do: :system
  defp other_scope(:system), do: :user

  defp abort(message) do
    IO.puts(:stderr, "fermix stop: #{message}")
    1
  end
end
