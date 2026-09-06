defmodule Fermix.CLI.ServiceCommand do
  @moduledoc """
  `fermix service install|uninstall` argv router and shared helpers
  for the start/stop/restart commands.

  Parses `--user|--system` and delegates to `Fermix.CLI.Service`.
  Returns a non-zero exit on any backend error so the operator sees
  the failure verbatim instead of a silent partial install.
  """

  alias Fermix.CLI.HomeOwner
  alias Fermix.CLI.Service
  alias FermixCore.BuildInfo

  @switches [user: :boolean, system: :boolean]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run([], deps) when is_list(deps), do: usage(2)
  def run([sub | rest], deps) when is_list(deps), do: dispatch(sub, rest, deps)

  defp dispatch("install", argv, deps), do: with_scope(argv, :install, "installed", deps)

  defp dispatch("uninstall", argv, deps),
    do: with_scope(argv, :uninstall, "uninstalled", deps)

  defp dispatch(unknown, _argv, _deps), do: unknown_subcommand(unknown)

  # The app-managed refusal precedes scope parsing: legacy unit scope is not a
  # choice this engine has, so reporting a scope error first would answer a
  # question the operator cannot act on and hide the one that matters.
  defp with_scope(argv, action, past_tense, deps) do
    build_info = Keyword.get(deps, :build_info, BuildInfo)
    service = Keyword.get(deps, :service, Service)
    home_owner = Keyword.get(deps, :home_owner, HomeOwner)

    cond do
      build_info.app_engine?() ->
        abort("this engine is managed by Fermix.app. Use Fermix.app background service controls.")

      # `install` only, and no wider: `uninstall` targets a unit the app does
      # not own and is the supported remedy for exactly the condition the
      # `legacy_service_unit` row reports, so refusing it would leave that row
      # with no command behind it.
      action == :install and
          home_owner.app_managed?(Keyword.take(deps, [:hello, :marker?, :socket_path])) ->
        abort(HomeOwner.refusal_sentence("fermix service install"))

      true ->
        dispatch_service(argv, action, past_tense, service)
    end
  end

  defp dispatch_service(argv, action, past_tense, service) do
    case parse_scope(argv, @switches) do
      {:ok, scope} ->
        run_action(
          fn selected_scope -> apply(service, action, [selected_scope]) end,
          scope,
          past_tense,
          "fermix service"
        )

      {:error, reason} ->
        abort(reason)
    end
  end

  @doc false
  @spec parse_scope([String.t()], keyword()) :: {:ok, :user | :system} | {:error, String.t()}
  def parse_scope(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, _argv, []} -> resolve_scope(opts)
      {_opts, _argv, invalid} -> {:error, "invalid options: #{inspect(invalid)}"}
    end
  end

  defp resolve_scope(opts) do
    case {Keyword.get(opts, :user, false), Keyword.get(opts, :system, false)} do
      {true, true} -> {:error, "--user and --system are mutually exclusive"}
      {true, _} -> {:ok, :user}
      {_, true} -> {:ok, :system}
      _ -> {:ok, :user}
    end
  end

  @doc false
  @spec run_action(
          (:user | :system -> :ok | {:error, term()}),
          :user | :system,
          String.t(),
          String.t()
        ) ::
          non_neg_integer()
  def run_action(action, scope, past_tense, command_label) do
    case action.(scope) do
      :ok ->
        IO.puts("#{command_label}: #{past_tense} #{scope}-scope unit.")
        0

      {:error, reason} ->
        IO.puts(:stderr, "#{command_label}: #{format_reason(reason)}")
        1
    end
  end

  @doc false
  def format_reason({:linger_failed, _code, message}), do: message
  def format_reason({:launchctl_failed, code, out}), do: "launchctl failed (#{code}): #{out}"
  def format_reason({:systemctl_failed, code, out}), do: "systemctl failed (#{code}): #{out}"
  def format_reason({:unsupported_os, os}), do: "unsupported OS: #{inspect(os)}"

  def format_reason({:stop_failed, pid}),
    do:
      "the daemon (pid #{pid}) did not exit after SIGTERM then SIGKILL — it may be wedged. " <>
        "Force it with `kill -9 #{pid}`, or `fermix service uninstall && fermix service install`."

  def format_reason(other), do: inspect(other)

  defp unknown_subcommand(name) do
    IO.puts(:stderr, "fermix service: unknown subcommand: #{name}")
    usage(2)
  end

  defp usage(exit_status) do
    out = if exit_status == 0, do: :stdio, else: :stderr

    IO.puts(out, """
    Usage:
      fermix service install   [--user|--system]   Install OS service unit
      fermix service uninstall [--user|--system]   Remove OS service unit
    """)

    exit_status
  end

  defp abort(message) do
    IO.puts(:stderr, "fermix service: #{message}")
    1
  end
end
