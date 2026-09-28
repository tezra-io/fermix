defmodule FermixCore.Management.Settings.Browser do
  @moduledoc """
  The `browser` section: the managed browser the agent's tasks run in.

  Every install has one, whichever door draws it, so the section is published
  everywhere rather than gated on a platform. Its first row is a fact rather
  than a setting: the browser the launcher would start for a task, by the name
  a person knows it by, or the sentence that there is none, which is the state
  `browser.install.start` exists to clear. A path never crosses the wire, so
  the row carries a name.

  The three rows below it are the `[fermix_core.browser]` keys a person sets:
  how tasks run (`default_profile`, one of the managed profiles, which is how
  the configuration already says headless or visible), how many tabs a browser
  keeps (`max_tabs`), and the private hosts it may open (`allowed_hosts`).
  None is boot-bound: a call reads the section when it runs, and a browser
  already running keeps its tab cap until it next starts.
  """

  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Config, as: BrowserConfig
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source

  @section %{id: "browser", pane: "browser", title: "Browser"}

  # The managed profiles a person chooses between, in the order a pane lists
  # them, each named for what the person sees rather than for its profile name.
  @run_options [
    {"fermix", "Automatically",
     "In a window where there is a display, otherwise in the background"},
    {"fermix_headless", "In the background", "No browser window opens"},
    {"fermix_visible", "In a window", "You can watch each step"}
  ]

  @executable_info "Fermix uses Google Chrome, Chromium or Google Chrome Canary when one is " <>
                     "installed, and otherwise Google Chrome for Testing, which it can download."
  @run_info "Each choice keeps its own browser profile, so a site you sign in to under one " <>
              "is signed out under the others."

  @doc "The one section this module owns."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: [@section]

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: section == @section.id

  @doc """
  The rows of the owned section.

  `opts` carries the test seam `resolve`: the arity-1 function that answers the
  browser tasks run in for a `[fermix_core.browser]` block.
  """
  @spec rows(String.t(), Source.snapshot(), keyword()) :: [Row.t()]
  def rows(section, snapshot, opts \\ [])

  def rows("browser", snapshot, opts) when is_map(snapshot) and is_list(opts) do
    block = Source.core(snapshot, :browser)
    restart = Row.restart?(:browser)
    resolve = Keyword.get(opts, :resolve, &ChromeLauncher.resolve_default/1)
    defaults = %BrowserConfig{}

    [
      executable_row(resolve.(block), restart),
      Row.new("browser_default_profile", :choice, "Run tasks",
        info: @run_info,
        value: Source.string(block, :default_profile, defaults.default_profile),
        options:
          Enum.map(@run_options, fn {value, label, hint} -> option(value, label, hint) end),
        restart: restart
      ),
      Row.new("browser_max_tabs", :number, "Most open tabs",
        footer:
          "Opening one more closes the oldest tab a task is not using. " <>
            "Takes effect the next time the browser starts.",
        value: Source.number(block, :max_tabs, defaults.max_tabs),
        min: 1,
        step: 1,
        format: :integer,
        restart: restart
      ),
      Row.new("browser_allowed_hosts", :list, "Private hosts the browser may open",
        footer:
          "Exact host names or addresses. The browser refuses private and internal " <>
            "addresses unless they are listed here.",
        value: allowed_hosts(block, defaults),
        restart: restart
      )
    ]
  end

  # The name is the value and the sentence is the footer, so a pane shows the
  # browser in force at a glance and says plainly when there is none. A refused
  # configuration is answered in its own words: the launcher would refuse the
  # same way, and an install would not clear it.
  defp executable_row(resolution, restart) do
    Row.new("browser_executable", :text, "Browser for tasks",
      footer: executable_footer(resolution),
      info: @executable_info,
      value: executable_value(resolution),
      read_only: true,
      restart: restart
    )
  end

  defp executable_value({:ok, %{label: label}}), do: label
  defp executable_value({:error, _error}), do: nil

  defp executable_footer({:ok, _found}), do: nil
  defp executable_footer({:error, _error} = refused), do: ChromeLauncher.sentence(refused)

  defp option(value, label, hint), do: Row.option(value, label, hint: hint)

  # The list in force: the settings file's own, or the shipped default when it
  # names none, so a save starts from what the browser actually allows.
  defp allowed_hosts(block, defaults) do
    case Keyword.fetch(block, :allowed_hosts) do
      {:ok, hosts} when is_list(hosts) -> Enum.map(hosts, &to_string/1)
      _absent -> defaults.allowed_hosts
    end
  end
end
