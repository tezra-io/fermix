defmodule Fermix.CLI.Setup.WebLauncher do
  @moduledoc """
  Service-first setup launcher.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.ServiceCommand
  alias FermixCore.Auth.Browser
  alias FermixCore.Setup.AccessToken
  alias FermixCore.Setup.ServiceActivation

  @default_port 4030
  @default_attempts 60
  @default_interval_ms 500

  @spec run(keyword()) :: :ok | {:error, String.t()}
  def run(opts) when is_list(opts) do
    puts = Keyword.get(opts, :puts, &IO.puts/1)

    with {:ok, _summary} <- activate(opts),
         {:ok, launch} <- mint_launch(opts),
         {:ok, port} <- setup_port(opts),
         url <- setup_url(port, launch.token),
         :ok <- announce_url(url, port, opts, puts),
         :ok <- wait_or_warn(opts, url, puts) do
      maybe_open(url, opts, puts)
      print_handoff(opts, puts)
      :ok
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, format_error(reason)}
      {:skipped, reason} -> {:error, format_skipped(reason)}
    end
  end

  defp mint_launch(opts) do
    if Keyword.get(opts, :rotate_token, false) do
      with {:ok, _token} <- AccessToken.rotate_setup_token(token_opts(opts)) do
        AccessToken.mint_launch_token(token_opts(opts))
      end
    else
      AccessToken.mint_launch_token(token_opts(opts))
    end
  end

  defp activate(opts) do
    scope = Keyword.fetch!(opts, :scope)

    activation_opts =
      opts
      |> Keyword.take([:service, :service_opts, :standalone?])
      |> Keyword.put(:no_service, Keyword.get(opts, :no_service, false))

    ServiceActivation.ensure_running(scope, activation_opts)
  end

  defp wait_or_warn(opts, url, puts) do
    case wait_for_live(opts) do
      :ok ->
        :ok

      {:error, :timeout} ->
        puts.("Fermix service was started, but readiness did not answer before the timeout.")
        puts.("Setup may still come up shortly: #{url}")
        puts.("Check with `fermix status` or `fermix logs -n 80`.")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec wait_for_live(keyword()) :: :ok | {:error, :timeout | term()}
  def wait_for_live(opts \\ []) when is_list(opts) do
    probe = Keyword.get(opts, :live_probe, fn -> default_live_probe(opts) end)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    attempts = Keyword.get(opts, :max_attempts, @default_attempts)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    poll_live(probe, sleep, attempts, interval)
  end

  defp poll_live(_probe, _sleep, attempts, _interval) when attempts <= 0, do: {:error, :timeout}

  defp poll_live(probe, sleep, attempts, interval) do
    case probe.() do
      :ok ->
        :ok

      {:error, _reason} ->
        sleep.(interval)
        poll_live(probe, sleep, attempts - 1, interval)
    end
  end

  defp default_live_probe(opts) do
    with {:ok, port} <- setup_port(opts),
         {:ok, %{"status" => "ok"}} <- Client.status(timeout: 500),
         :ok <- tcp_reachable?(port) do
      :ok
    else
      {:ok, _other} -> {:error, :daemon_unhealthy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tcp_reachable?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp announce_url(url, port, opts, puts) do
    puts.("Open Fermix setup in your browser:")
    puts.("  #{url}")

    if Keyword.get(opts, :ssh_hint, false) do
      puts.("  (over SSH: ssh -L #{port}:127.0.0.1:#{port} user@host, then open the URL)")
    end

    puts.("Waiting for the daemon to come up...")
    :ok
  end

  defp maybe_open(url, opts, puts) do
    if Keyword.get(opts, :no_browser, false) do
      puts.("Browser launch skipped (--no-browser); open the URL above.")
      :ok
    else
      case open_url(opts).(url) do
        :ok ->
          puts.("Opening your browser...")
          :ok

        {:error, reason} ->
          puts.(
            "Could not open a browser automatically (#{inspect(reason)}); open this URL manually:"
          )

          puts.("  #{url}")
          :ok
      end
    end
  end

  defp open_url(opts), do: Keyword.get(opts, :opener, &Browser.open/1)

  defp print_handoff(opts, puts) do
    puts.("Fermix is running (#{Keyword.fetch!(opts, :scope)} service).")
    puts.("Use `fermix status` to check the daemon, or `fermix stop` to stop it.")
  end

  defp setup_url(port, token) do
    "http://127.0.0.1:#{port}/setup?t=#{URI.encode_www_form(token)}"
  end

  defp setup_port(opts) do
    cond do
      valid_port?(Keyword.get(opts, :port)) ->
        {:ok, Keyword.fetch!(opts, :port)}

      not is_nil(Keyword.get(opts, :port)) ->
        {:error, "invalid --port #{inspect(Keyword.get(opts, :port))}; expected 1..65535"}

      true ->
        env_or_default_port(System.get_env("PORT"))
    end
  end

  defp env_or_default_port(nil), do: {:ok, @default_port}
  defp env_or_default_port(""), do: {:ok, @default_port}

  defp env_or_default_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port > 0 and port <= 65_535 ->
        {:ok, port}

      _invalid ->
        {:error, "invalid PORT=#{inspect(value)}; expected 1..65535"}
    end
  end

  defp valid_port?(port) when is_integer(port), do: port > 0 and port <= 65_535
  defp valid_port?(_port), do: false

  defp token_opts(opts), do: Keyword.get(opts, :token_opts, [])

  defp format_error({:install_failed, reason}),
    do: "service install failed: #{format_reason(reason)}"

  defp format_error({:start_failed, reason}), do: "service start failed: #{format_reason(reason)}"

  defp format_error({:restart_failed, restart_reason, :start_failed, start_reason}) do
    "service restart failed: #{format_reason(restart_reason)}; " <>
      "service start failed: #{format_reason(start_reason)}"
  end

  defp format_error({:restart_failed, reason}),
    do: "service restart failed: #{format_reason(reason)}"

  defp format_error(reason), do: inspect(reason)

  defp format_skipped(:not_standalone),
    do: "service activation skipped: run web setup from the packaged standalone binary"

  defp format_skipped(:opted_out),
    do: "service activation skipped: --no-service cannot serve web setup"

  defp format_skipped(reason), do: "service activation skipped: #{inspect(reason)}"

  defp format_reason(reason), do: ServiceCommand.format_reason(reason)
end
