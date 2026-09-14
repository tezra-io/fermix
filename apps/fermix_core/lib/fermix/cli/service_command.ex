defmodule Fermix.CLI.ServiceCommand do
  @moduledoc """
  `fermix service install|uninstall|status` argv router and shared helpers
  for the start/stop/restart commands.

  Two audiences, one result. A person reads labelled lines; the desktop client
  reads `--json`, whose stdout carries the schema-versioned envelope and nothing
  else (M38 §4.6) while every sentence and every progress line goes to stderr.
  Both render the same result map and the same refusal sentence, so they can
  never disagree about what happened.

  Exit 0 when the verb succeeded, 1 when it refused, 2 on a usage error.
  """

  alias Fermix.CLI.HomeOwner
  alias Fermix.CLI.MachineOutput
  alias Fermix.CLI.Service
  alias FermixCore.BuildInfo
  alias FermixCore.Harness.Identity

  @scope_switches [user: :boolean, system: :boolean]
  @install_switches @scope_switches ++ [json: :boolean, home: :string, port: :integer]
  @uninstall_switches @scope_switches ++ [json: :boolean]
  @status_switches [json: :boolean]

  @spec run([String.t()]) :: non_neg_integer()
  def run(argv), do: run(argv, [])

  @doc false
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run([], deps) when is_list(deps), do: usage(2)
  def run([sub | rest], deps) when is_list(deps), do: dispatch(sub, rest, deps)

  defp dispatch("install", argv, deps), do: mutate(:install, argv, deps)
  defp dispatch("uninstall", argv, deps), do: mutate(:uninstall, argv, deps)
  defp dispatch("status", argv, deps), do: status(argv, deps)
  defp dispatch(unknown, _argv, _deps), do: unknown_subcommand(unknown)

  # The app-managed refusal precedes scope parsing: legacy unit scope is not a
  # choice this engine has, so reporting a scope error first would answer a
  # question the operator cannot act on and hide the one that matters. The
  # output format therefore has to be known before argv is parsed, and one flag
  # read off argv is what buys that ordering.
  defp mutate(action, argv, deps) do
    json? = "--json" in argv

    case guard(action, deps) do
      :ok -> parse_and_run(action, argv, json?, deps)
      {:error, sentence} -> refuse_app_managed(sentence, json?)
    end
  end

  defp parse_and_run(action, argv, json?, deps) do
    case parse(argv, switches(action)) do
      {:ok, options} -> apply_action(action, %{options | json?: json?}, deps)
      {:error, message} -> usage_error(message)
    end
  end

  defp switches(:install), do: @install_switches
  defp switches(:uninstall), do: @uninstall_switches

  defp guard(action, deps) do
    build_info = Keyword.get(deps, :build_info, BuildInfo)
    home_owner = Keyword.get(deps, :home_owner, HomeOwner)

    cond do
      build_info.app_engine?() ->
        {:error,
         "this engine is managed by Fermix.app. Use Fermix.app background service controls."}

      # `install` only, and no wider: `uninstall` targets a unit the app does
      # not own and is the supported remedy for exactly the condition the
      # `legacy_service_unit` row reports, so refusing it would leave that row
      # with no command behind it.
      action == :install and
          home_owner.app_managed?(Keyword.take(deps, [:hello, :marker?, :socket_path])) ->
        {:error, HomeOwner.refusal_sentence("fermix service install")}

      true ->
        :ok
    end
  end

  defp apply_action(:install, options, deps) do
    service = Keyword.get(deps, :service, Service)

    case service.install(options.scope, service_opts(options, deps)) do
      :ok -> report_action(options, "installed")
      {:ok, status} -> report_status(options, status)
      {:error, reason} -> report_failure(options, reason, deps)
    end
  end

  defp apply_action(:uninstall, options, deps) do
    service = Keyword.get(deps, :service, Service)

    case service.uninstall(options.scope, service_opts(options, deps)) do
      :ok -> report_action(options, "uninstalled")
      {:error, reason} -> report_failure(options, reason, deps)
    end
  end

  defp status(argv, deps) do
    service = Keyword.get(deps, :service, Service)

    with {:ok, options} <- parse(argv, @status_switches),
         {:ok, status} <- service.status(service_opts(options, deps)) do
      report_status(options, status)
    else
      {:error, message} when is_binary(message) -> usage_error(message)
      {:error, reason} -> report_failure(status_options(argv), reason, deps)
    end
  end

  # `status` refuses before its own argv is parsed only when the parse failed,
  # which `usage_error/1` already answered; every other refusal renders in the
  # format the caller asked for.
  defp status_options(argv), do: %{scope: :user, json?: "--json" in argv, home: nil, port: nil}

  defp service_opts(options, deps) do
    chosen =
      Enum.reject([home: options.home, port: options.port], fn {_key, value} -> is_nil(value) end)

    Keyword.merge(Keyword.get(deps, :service_opts, []), chosen)
  end

  # ── output ─────────────────────────────────────────────────────────────────

  defp report_action(%{json?: true} = options, past_tense) do
    IO.puts(MachineOutput.ok(%{"action" => past_tense, "scope" => to_string(options.scope)}))
    0
  end

  defp report_action(options, past_tense) do
    IO.puts("fermix service: #{past_tense} #{options.scope}-scope unit.")
    0
  end

  defp report_status(%{json?: true}, status) do
    IO.puts(MachineOutput.ok(status))
    0
  end

  defp report_status(_options, status) do
    Enum.each(status_lines(status), fn {label, value} ->
      IO.puts(String.pad_trailing(label <> ":", 14) <> value)
    end)

    0
  end

  @doc """
  The published code and details for one service reason, or `:untyped`.

  `fermix restart`'s packaged path renders the same refusals this module does,
  and a second copy of the table is a second vocabulary waiting to drift.
  """
  @spec published_reason(term(), keyword()) :: {atom(), keyword()} | :untyped
  def published_reason(reason, deps \\ []), do: published(reason, deps)

  defp report_failure(options, reason, deps) do
    case published(reason, deps) do
      {code, details} -> refuse(code, details, options)
      :untyped -> legacy_failure(options, reason)
    end
  end

  defp refuse(code, details, %{json?: true}) do
    IO.puts(MachineOutput.error(code, details))
    1
  end

  defp refuse(code, details, _options) do
    IO.puts(:stderr, "fermix service: " <> MachineOutput.sentence(code, details))
    1
  end

  # The standalone install path keeps its own reasons, and they have no published
  # code: an engine that writes its own unit is not the packaged service the
  # desktop client drives.
  defp legacy_failure(%{json?: true}, reason) do
    IO.puts(MachineOutput.error(:systemctl_failed, output: format_reason(reason)))
    1
  end

  defp legacy_failure(_options, reason) do
    IO.puts(:stderr, "fermix service: #{format_reason(reason)}")
    1
  end

  defp refuse_app_managed(sentence, true) do
    IO.puts(:stderr, "fermix service: #{sentence}")
    IO.puts(MachineOutput.error(:app_managed))
    1
  end

  defp refuse_app_managed(sentence, false) do
    IO.puts(:stderr, "fermix service: #{sentence}")
    1
  end

  defp status_lines(status) do
    [
      {"Service", "#{state(status["active"], "active", "inactive")} (#{status["sub_state"]})"},
      {"Enabled", state(status["enabled"], "yes", "no")},
      {"Home", home_line(status["binding"])},
      {"Unit", unit_line(status["unit"])},
      {"Linger", status["linger"]},
      {"Pid", value(status["pid"])},
      {"Restarts", value(status["restart_count"])},
      {"Listener", value(status["listener"]["origin"])},
      {"Installed", installed_line(status["installed"])},
      {"Running", value(status["running"] && status["running"]["build_id"])},
      {"Alignment", status["alignment"]}
    ]
  end

  defp home_line(%{"state" => "bound", "home" => home}), do: home
  defp home_line(%{"state" => "unbound"}), do: "not set"
  defp home_line(%{"state" => "invalid", "reason" => reason}), do: "unreadable (#{reason})"

  defp unit_line(%{"effective_path" => nil}), do: "none"

  defp unit_line(unit) do
    unit["effective_path"] <> " (" <> unit_owner(unit) <> ")"
  end

  defp unit_owner(%{"foreign" => true}), do: "not written by Fermix"
  defp unit_owner(%{"legacy_generated" => true}), do: "written by an earlier Fermix"
  defp unit_owner(%{"vendor" => true}), do: "package"
  defp unit_owner(_other), do: "unknown"

  defp installed_line(installed) do
    "#{installed["product_version"]} (#{value(installed["build_id"])}) " <>
      "integrity #{installed["integrity"]}"
  end

  defp state(true, yes, _no), do: yes
  defp state(_false, _yes, no), do: no

  defp value(nil), do: "unknown"
  defp value(value) when is_integer(value), do: Integer.to_string(value)
  defp value(value), do: value

  # ── reasons ────────────────────────────────────────────────────────────────

  defp published(reason, _deps) when reason in ~w(
         user_manager_unreachable loginctl_absent no_identity service_unbound
         activation_timeout health_unavailable foreign_distribution
         idle_restart_unavailable
       )a do
    {reason, []}
  end

  defp published({:invalid_home, sentence}, _deps), do: {:invalid_home, [reason: sentence]}
  defp published({:invalid_port, sentence}, _deps), do: {:invalid_port, [reason: sentence]}

  defp published({:lifecycle_refused, detail}, _deps),
    do: {:lifecycle_refused, [output: detail]}

  defp published({:config_write_failed, reason}, _deps),
    do: {:config_write_failed, [output: detail(reason)]}

  defp published({:home_change_refused, home}, _deps), do: {:home_change_refused, [home: home]}
  defp published({:foreign_unit, path}, _deps), do: {:foreign_unit, [path: path]}

  defp published({:linger_denied, output}, deps),
    do: {:linger_denied, [output: output, user: account(deps)]}

  defp published({:linger_unknown, output}, _deps),
    do: {:systemctl_failed, [output: output]}

  defp published({:systemctl_failed, _status, output}, _deps),
    do: {:systemctl_failed, [output: output]}

  defp published({:binding_write_failed, reason}, _deps),
    do: {:binding_write_failed, [output: detail(reason)]}

  defp published(_other, _deps), do: :untyped

  # A reason that already carries an operator sentence is printed as written; a
  # bare posix atom or tuple has no sentence and is inspected, which is the
  # honest answer for a fault nobody has written words for yet.
  defp detail(reason) when is_binary(reason), do: reason
  defp detail(reason), do: inspect(reason)

  defp account(deps) do
    username = Keyword.get(deps, :username, &Identity.username/1)
    username.([]) || "USER"
  end

  # ── parsing ────────────────────────────────────────────────────────────────

  defp parse(argv, switches) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, [], []} -> options(opts, switches)
      {_opts, [extra | _rest], []} -> {:error, "unexpected argument: #{extra}"}
      {_opts, _argv, invalid} -> {:error, "invalid options: #{inspect(invalid)}"}
    end
  end

  defp options(opts, switches) do
    with {:ok, scope} <- scope(opts, switches) do
      {:ok,
       %{
         scope: scope,
         json?: Keyword.get(opts, :json, false),
         home: Keyword.get(opts, :home),
         port: Keyword.get(opts, :port)
       }}
    end
  end

  defp scope(opts, switches) do
    if Keyword.has_key?(switches, :user), do: resolve_scope(opts), else: {:ok, :user}
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
  def format_reason({:launchctl_failed, code, out}), do: "launchctl failed (#{code}): #{out}"
  def format_reason({:systemctl_failed, code, out}), do: "systemctl failed (#{code}): #{out}"
  def format_reason({:unsupported_os, os}), do: "unsupported OS: #{inspect(os)}"

  def format_reason(reason) when is_atom(reason) or is_tuple(reason) do
    case published(reason, []) do
      {code, details} -> MachineOutput.sentence(code, details)
      :untyped -> stop_failure(reason)
    end
  end

  def format_reason(other), do: inspect(other)

  defp stop_failure({:stop_failed, pid}) do
    "the daemon (pid #{pid}) did not exit after SIGTERM then SIGKILL — it may be wedged. " <>
      "Force it with `kill -9 #{pid}`, or `fermix service uninstall && fermix service install`."
  end

  defp stop_failure(other), do: inspect(other)

  defp unknown_subcommand(name) do
    IO.puts(:stderr, "fermix service: unknown subcommand: #{name}")
    usage(2)
  end

  defp usage_error(message) do
    IO.puts(:stderr, "fermix service: #{message}")
    usage(2)
  end

  defp usage(exit_status) do
    out = if exit_status == 0, do: :stdio, else: :stderr

    IO.puts(out, """
    Usage:
      fermix service install   [--user|--system] [--json] [--home PATH] [--port N]
      fermix service uninstall [--user|--system] [--json]
      fermix service status    [--json]
    """)

    exit_status
  end
end
