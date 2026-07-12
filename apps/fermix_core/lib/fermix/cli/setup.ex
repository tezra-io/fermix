defmodule Fermix.CLI.Setup do
  @moduledoc """
  Release-safe `fermix setup` command.

  Parses argv with `OptionParser` and delegates to
  `FermixCore.Setup.Runtime.run/2` using stdio-backed IO.
  """

  alias Fermix.CLI.ServiceCommand
  alias Fermix.CLI.Setup.WebLauncher
  alias FermixCore.Setup.Runtime
  alias FermixCore.Setup.ServiceActivation
  alias FermixCore.Setup.Wizard

  @switches [
    openai_api_key: :string,
    anthropic_api_key: :string,
    xai_api_key: :string,
    openrouter_api_key: :string,
    mistral_api_key: :string,
    ollama_base_url: :string,
    provider: :string,
    default_model: :string,
    reasoning_effort: :string,
    fast: :boolean,
    realtime_enabled: :boolean,
    realtime_api_key: :string,
    realtime_voice: :string,
    realtime_max_session_minutes: :integer,
    realtime_max_cost_cents: :integer,
    realtime_persist_transcripts: :boolean,
    image_backend: :string,
    image_model: :string,
    google_api_key: :string,
    transcription_backend: :string,
    transcription_model: :string,
    transcription_api_key: :string,
    telegram_bot_token: :string,
    telegram_owner_user_id: :string,
    whatsapp_access_token: :string,
    whatsapp_phone_number_id: :string,
    whatsapp_verify_token: :string,
    whatsapp_app_secret: :string,
    whatsapp_owner_user_id: :string,
    discord_bot_token: :string,
    discord_bot_user_id: :string,
    discord_owner_user_id: :string,
    slack_bot_token: :string,
    slack_signing_secret: :string,
    slack_owner_user_id: :string,
    signal_account: :string,
    signal_owner_user_id: :string,
    print_state: :boolean,
    reconfigure: :boolean,
    migrate_secrets: :boolean,
    import_codex: :boolean,
    no_browser: :boolean,
    skip_probe: :boolean,
    port: :integer,
    timeout: :integer,
    web: :boolean,
    cli: :boolean,
    terminal: :boolean,
    no_service: :boolean,
    system: :boolean,
    user: :boolean,
    rotate_token: :boolean
  ]

  @spec run([String.t()]) :: non_neg_integer()
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, run_opts \\ []) when is_list(argv) and is_list(run_opts) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, _argv, []} -> dispatch(opts, run_opts)
      {_opts, _argv, invalid} -> invalid_options(invalid)
    end
  end

  @spec supervision_required?([String.t()]) :: boolean()
  @spec supervision_required?([String.t()], keyword()) :: boolean()
  def supervision_required?(argv, run_opts \\ []) when is_list(argv) and is_list(run_opts) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, _argv, []} -> terminal_mode?(opts, run_opts)
      {_opts, _argv, _invalid} -> false
    end
  end

  defp dispatch(opts, run_opts) do
    with {:ok, scoped_opts} <- resolve_scope(opts),
         :ok <- validate_mode(scoped_opts) do
      run_dispatch(scoped_opts, run_opts)
    else
      {:error, reason} -> abort(reason)
    end
  end

  defp run_dispatch(opts, run_opts) do
    if terminal_mode?(opts, run_opts) do
      run_terminal(opts, run_opts)
    else
      run_web(opts, run_opts)
    end
  end

  defp run_terminal(opts, run_opts) do
    runtime = Keyword.get(run_opts, :runtime, &Runtime.run/2)
    io = Keyword.take(run_opts, [:puts, :prompt])

    runtime_opts =
      Keyword.drop(opts, [:scope, :user, :system, :web, :cli, :terminal, :rotate_token])

    case runtime.(runtime_opts, io) do
      :ok -> finish_terminal_setup(opts, run_opts, io)
      {:error, reason} -> abort(reason)
    end
  end

  defp finish_terminal_setup(opts, run_opts, io) do
    cond do
      terminal_service_activation_disabled?(opts) ->
        0

      not terminal_setup_ready?(run_opts) ->
        0

      true ->
        activate_terminal_service(opts, run_opts, Keyword.get(io, :puts, &IO.puts/1))
    end
  end

  defp terminal_service_activation_disabled?(opts) do
    Keyword.get(opts, :no_service, false) or Keyword.get(opts, :print_state, false) or
      Keyword.get(opts, :migrate_secrets, false)
  end

  defp terminal_setup_ready?(run_opts) do
    run_opts
    |> Keyword.get(:setup_ready?, &default_setup_ready?/0)
    |> then(fn fun -> fun.() end)
  end

  defp default_setup_ready? do
    Wizard.report().status == :ready
  end

  defp activate_terminal_service(opts, run_opts, puts) do
    scope = Keyword.fetch!(opts, :scope)

    case ServiceActivation.ensure_running(scope, activation_opts(opts, run_opts)) do
      {:ok, _summary} ->
        print_terminal_handoff(scope, puts)
        0

      {:skipped, :not_standalone} ->
        print_manual_service_steps(puts)
        0

      {:skipped, :opted_out} ->
        0

      {:error, reason} ->
        abort("service activation failed: #{format_activation_error(reason)}")
    end
  end

  defp activation_opts(opts, run_opts) do
    run_opts
    |> Keyword.take([:service, :service_opts, :standalone?])
    |> Keyword.put(:no_service, Keyword.get(opts, :no_service, false))
  end

  defp print_terminal_handoff(scope, puts) do
    puts.("Fermix is running (#{scope} service).")
    puts.("Use `fermix status` to check the daemon, or `fermix stop` to stop it.")
  end

  defp print_manual_service_steps(puts) do
    puts.(
      "Setup saved. This is not the packaged standalone binary, so the service was not changed."
    )

    puts.("Run `fermix service install` then `fermix start`, or use `fermix run`.")
  end

  defp run_web(opts, run_opts) do
    launcher = Keyword.get(run_opts, :web_launcher, &WebLauncher.run/1)

    launch_opts =
      opts
      |> Keyword.take([:no_browser, :no_service, :rotate_token, :port])
      |> Keyword.put(:scope, Keyword.fetch!(opts, :scope))
      |> Keyword.put(:no_browser, Keyword.get(opts, :no_browser, false))
      |> Keyword.put(
        :ssh_hint,
        Keyword.get(opts, :web, false) and not display_available?(run_opts)
      )
      |> put_run_opt(run_opts, :puts)
      |> put_run_opt(run_opts, :service)
      |> put_run_opt(run_opts, :service_opts)
      |> put_run_opt(run_opts, :standalone?)
      |> put_run_opt(run_opts, :live_probe)
      |> put_run_opt(run_opts, :sleep)
      |> put_run_opt(run_opts, :opener)
      |> put_run_opt(run_opts, :token_opts)

    case launcher.(launch_opts) do
      :ok -> 0
      {:error, reason} -> abort(reason)
    end
  end

  defp put_run_opt(opts, run_opts, key) do
    case Keyword.fetch(run_opts, key) do
      {:ok, value} -> Keyword.put(opts, key, value)
      :error -> opts
    end
  end

  defp terminal_mode?(opts, run_opts) do
    cond do
      Keyword.get(opts, :web, false) -> false
      explicit_terminal?(opts) -> true
      provided_setup_answers?(opts) -> true
      terminal_action?(opts) -> true
      not standalone?(run_opts) -> true
      not display_available?(run_opts) -> true
      true -> false
    end
  end

  defp explicit_terminal?(opts) do
    Keyword.get(opts, :cli, false) or Keyword.get(opts, :terminal, false) or
      Keyword.get(opts, :no_service, false)
  end

  defp provided_setup_answers?(opts), do: Runtime.provided_answers(opts) != []

  defp terminal_action?(opts) do
    Enum.any?([:print_state, :reconfigure, :migrate_secrets, :import_codex], fn key ->
      Keyword.get(opts, key, false)
    end)
  end

  defp standalone?(run_opts) do
    run_opts
    |> Keyword.get(:standalone?, &Burrito.Util.running_standalone?/0)
    |> then(fn fun -> fun.() end)
  end

  defp display_available?(run_opts) do
    run_opts
    |> Keyword.get(:display?, &default_display_available?/0)
    |> then(fn fun -> fun.() end)
  end

  defp default_display_available? do
    case :os.type() do
      {:unix, :darwin} -> true
      {:win32, _} -> true
      {:unix, _} -> present_env?("DISPLAY") or present_env?("WAYLAND_DISPLAY")
    end
  end

  defp present_env?(name) do
    System.get_env(name) not in [nil, ""]
  end

  defp resolve_scope(opts) do
    case {Keyword.get(opts, :user, false), Keyword.get(opts, :system, false)} do
      {true, true} -> {:error, "--user and --system are mutually exclusive"}
      {true, _} -> {:ok, Keyword.put(opts, :scope, :user)}
      {_, true} -> {:ok, Keyword.put(opts, :scope, :system)}
      _ -> {:ok, Keyword.put(opts, :scope, :user)}
    end
  end

  defp validate_mode(opts) do
    cond do
      Keyword.get(opts, :web, false) and Keyword.get(opts, :no_service, false) ->
        {:error, "--web and --no-service are mutually exclusive"}

      Keyword.get(opts, :web, false) and explicit_terminal?(Keyword.drop(opts, [:no_service])) ->
        {:error, "--web cannot be combined with --cli or --terminal"}

      true ->
        :ok
    end
  end

  defp invalid_options(invalid) do
    abort("invalid options: #{inspect(invalid)}")
  end

  defp format_activation_error({:install_failed, reason}),
    do: "service install failed: #{format_reason(reason)}"

  defp format_activation_error({:start_failed, reason}),
    do: "service start failed: #{format_reason(reason)}"

  defp format_activation_error({:restart_failed, restart_reason, :start_failed, start_reason}) do
    "service restart failed: #{format_reason(restart_reason)}; " <>
      "service start failed: #{format_reason(start_reason)}"
  end

  defp format_activation_error({:restart_failed, reason}),
    do: "service restart failed: #{format_reason(reason)}"

  defp format_activation_error(reason), do: inspect(reason)

  defp format_reason(reason), do: ServiceCommand.format_reason(reason)

  defp abort(message) do
    IO.puts(:stderr, "fermix setup: #{message}")
    1
  end
end
