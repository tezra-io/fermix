defmodule Fermix.CLI.AppRoute do
  @moduledoc """
  Opens a route owned by the installed Fermix macOS application.

  An app-managed engine owns none of the surfaces behind these routes: setup,
  uninstall, and updating all belong to the signed application. The CLI hands
  the intent over and reports whether the hand-off was accepted — never whether
  the surface finished its work.

  Opening a route is deliberately unlogged. The daemon log is an operator
  artifact that outlives the command, and a route line there would record GUI
  navigation nobody can act on.
  """

  alias FermixCore.Auth.Browser

  @routes %{
    setup: "fermix://setup",
    uninstall: "fermix://uninstall",
    update: "fermix://update"
  }

  # One surface name and one remediation per route, so `fermix setup`,
  # `fermix uninstall`, and `fermix upgrade` cannot describe the same
  # application surface three different ways.
  @surfaces %{
    setup: {"Fermix setup", "Open Fermix.app and finish setup."},
    uninstall: {"Fermix uninstall", "Open Fermix.app and use the uninstall controls."},
    update: {"Fermix update settings", "Open Fermix.app and check for updates."}
  }

  @type route :: :setup | :uninstall | :update

  @spec open(route(), keyword()) :: :ok | {:error, term()}
  def open(route, opts \\ []) when is_map_key(@routes, route) and is_list(opts) do
    opener = Keyword.get(opts, :opener, &Browser.open/1)
    opener.(Map.fetch!(@routes, route))
  end

  @doc """
  Opens `route` for `command` and prints the one line the operator gets.

  Returns the command's exit status. Opener failure reasons stay internal: they
  name executables and OS exit codes, and the operator's next step is the same
  either way.
  """
  @spec open_and_report(route(), String.t(), keyword()) :: non_neg_integer()
  def open_and_report(route, command, opts \\ [])
      when is_map_key(@surfaces, route) and is_binary(command) and is_list(opts) do
    {surface, remediation} = Map.fetch!(@surfaces, route)

    case open(route, opts) do
      :ok ->
        IO.puts("Opened #{surface}.")
        0

      {:error, _reason} ->
        IO.puts(:stderr, "#{command}: could not open #{surface}. #{remediation}")
        1
    end
  end
end
