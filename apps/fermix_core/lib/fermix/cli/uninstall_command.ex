defmodule Fermix.CLI.UninstallCommand do
  @moduledoc """
  `fermix uninstall` — hands removal to the owner of this installation.

  An app-managed engine opens the application's uninstall route: only the app
  can unregister its background agent, and the route carries the confirmation
  and Fermix-home preservation promises with it.

  Every other installation was placed by a package manager or by hand, so no
  single removal step is correct. The command refuses and names the two things
  it does know: the service unit this binary installed, and the installer that
  owns the binary.
  """

  alias Fermix.CLI.AppRoute
  alias FermixCore.BuildInfo

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, deps) when is_list(argv) and is_list(deps) do
    build_info = Keyword.get(deps, :build_info, BuildInfo)

    cond do
      argv != [] -> unknown_arguments(argv)
      build_info.app_engine?() -> open_route(deps)
      true -> refuse_standalone()
    end
  end

  defp open_route(deps) do
    AppRoute.open_and_report(:uninstall, "fermix uninstall", Keyword.get(deps, :route_opts, []))
  end

  defp refuse_standalone do
    IO.puts(
      :stderr,
      "fermix uninstall: this installation is not managed by Fermix.app. " <>
        "Remove the service unit with `fermix service uninstall`, then remove the " <>
        "binary with the package manager that installed it. " <>
        "Your Fermix home is never removed by either step."
    )

    1
  end

  defp unknown_arguments(argv) do
    IO.puts(:stderr, "fermix uninstall: unexpected arguments: #{Enum.join(argv, " ")}")
    2
  end
end
