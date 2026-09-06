defmodule Fermix.CLI.PairCommand do
  @moduledoc """
  Opens one daemon-owned mobile pairing window and confirms its SAS interactively.

  The command never reads or writes the pairing store itself. The running daemon
  owns the listener, the one-time window, and device persistence.
  """

  alias Fermix.CLI.Daemon.Client

  @call_timeout_ms 5_000
  @wait_timeout_ms 125_000
  @session_id_pattern ~r/^[A-Za-z0-9_-]{1,128}$/
  @sas_pattern ~r/^\d{6}$/
  @uuid_pattern ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  @type request_fun :: (String.t(), map(), pos_integer() ->
                          {:ok, map()} | {:error, term()})

  @type connection_fun :: ((request_fun() -> non_neg_integer()) ->
                             non_neg_integer() | {:error, term()})

  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    io = io_devices(opts)

    case argv do
      [] -> run_connected(io, connection_fun(opts))
      _ -> usage(io)
    end
  end

  defp run_connected(io, connect) do
    case connect.(fn request -> pair(io, request) end) do
      status when is_integer(status) and status >= 0 -> status
      {:error, :not_running} -> daemon_not_running(io)
      {:error, reason} -> fail(io, "fermix pair: #{format_reason(reason)}")
      other -> fail(io, "fermix pair: invalid control connection result #{inspect(other)}")
    end
  end

  defp pair(io, request) do
    with {:ok, window} <- rpc(request, "mobile_pair_begin", %{}, @call_timeout_ms) do
      run_window(window, io, request)
    else
      {:error, :not_running} -> daemon_not_running(io)
      {:error, reason} -> fail(io, "fermix pair: #{format_reason(reason)}")
    end
  end

  defp run_window(window, io, request) do
    result =
      with :ok <- print_window(window, io),
           {:ok, pairing} <- await_request(request, window),
           approved? <- prompt_approval(pairing, io),
           {:ok, result} <- decide(request, window, approved?),
           :ok <- print_decision(result, approved?, io) do
        :ok
      end

    case result do
      :ok -> 0
      {:error, reason} -> cancel_and_fail(request, window, io, reason)
    end
  end

  defp cancel_and_fail(request, window, io, reason) do
    session_id = Map.get(window, "session_id")

    case rpc(
           request,
           "mobile_pair_cancel",
           %{"session_id" => session_id},
           @call_timeout_ms
         ) do
      {:ok, %{"cancelled" => true}} -> fail(io, "fermix pair: #{format_reason(reason)}")
      {:error, cancel_reason} -> fail(io, cleanup_error(reason, cancel_reason))
      {:ok, other} -> fail(io, cleanup_error(reason, {:invalid_cancel_reply, other}))
    end
  end

  defp cleanup_error(reason, cancel_reason) do
    "fermix pair: #{format_reason(reason)}; pairing cleanup failed: #{format_reason(cancel_reason)}"
  end

  defp print_window(window, io) do
    with :ok <- validate_session_id(Map.get(window, "session_id")),
         uri when is_binary(uri) and uri != "" <- Map.get(window, "uri"),
         true <- String.starts_with?(uri, "fermix://pair?"),
         qr when is_binary(qr) and qr != "" <- Map.get(window, "qr"),
         expires when is_integer(expires) and expires > 0 <- Map.get(window, "expires_in_s") do
      IO.puts(io.stdout, "Scan this QR code in Fermix for iOS (expires in #{expires}s):")
      IO.puts(io.stdout, qr)
      IO.puts(io.stdout, "Manual pairing URI: #{uri}")
      :ok
    else
      _ -> {:error, :invalid_pairing_window}
    end
  end

  defp await_request(request, window) do
    session_id = Map.get(window, "session_id")

    with {:ok, pairing} <-
           rpc(request, "mobile_pair_wait", %{"session_id" => session_id}, @wait_timeout_ms),
         :ok <- validate_pairing_request(pairing) do
      {:ok, pairing}
    end
  end

  defp validate_pairing_request(pairing) when is_map(pairing) do
    valid? =
      valid_text?(Map.get(pairing, "name")) and
        valid_text?(Map.get(pairing, "model")) and
        Regex.match?(@sas_pattern, Map.get(pairing, "sas", ""))

    if valid?, do: :ok, else: {:error, :invalid_pairing_request}
  end

  defp validate_pairing_request(_pairing), do: {:error, :invalid_pairing_request}

  defp prompt_approval(pairing, io) do
    prompt =
      "#{safe_field(pairing["model"])} '#{safe_field(pairing["name"])}' requests pairing. " <>
        "Phone shows #{pairing["sas"]}. Approve? [y/N] "

    IO.write(io.stdout, prompt)

    case IO.gets(io.stdin, "") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      :eof -> false
      {:error, _reason} -> false
    end
  end

  defp decide(request, window, approved?) do
    params = %{"session_id" => Map.get(window, "session_id"), "approved" => approved?}
    rpc(request, "mobile_pair_decide", params, @call_timeout_ms)
  end

  defp print_decision(result, true, io) do
    with true <- Map.get(result, "approved") == true,
         {:ok, device_id} <- valid_device_id(Map.get(result, "device_id")),
         name when is_binary(name) and name != "" <- Map.get(result, "name") do
      IO.puts(io.stdout, "\npaired #{safe_field(name)} (#{device_id})")
      :ok
    else
      _ -> {:error, :invalid_pairing_approval}
    end
  end

  defp print_decision(result, false, io) do
    if Map.get(result, "approved") == false do
      IO.puts(io.stdout, "\npairing denied")
      :ok
    else
      {:error, :invalid_pairing_denial}
    end
  end

  defp rpc(request, method, params, timeout) do
    case request.(method, params, timeout) do
      {:ok, %{"status" => "ok", "result" => result}} when is_map(result) -> {:ok, result}
      {:ok, %{"status" => "error", "reason" => reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_daemon_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp connection_fun(opts) do
    Keyword.get(opts, :with_connection, fn callback -> Client.with_connection(callback) end)
  end

  defp io_devices(opts) do
    %{
      stdin: Keyword.get(opts, :stdin, :stdio),
      stdout: Keyword.get(opts, :stdout, :stdio),
      stderr: Keyword.get(opts, :stderr, :stderr)
    }
  end

  defp usage(io) do
    IO.puts(io.stderr, "usage: fermix pair")
    2
  end

  defp daemon_not_running(io) do
    fail(io, "Fermix daemon is not running — start it with `fermix start`, then retry")
  end

  defp fail(io, message) do
    IO.puts(io.stderr, message)
    1
  end

  defp validate_session_id(value) when is_binary(value) do
    if Regex.match?(@session_id_pattern, value), do: :ok, else: :error
  end

  defp validate_session_id(_value), do: :error

  defp valid_device_id(value) when is_binary(value) do
    if Regex.match?(@uuid_pattern, value), do: {:ok, String.downcase(value)}, else: :error
  end

  defp valid_device_id(_value), do: :error
  defp valid_text?(value), do: is_binary(value) and value != "" and byte_size(value) <= 128

  # The daemon refuses control characters at pairing intake, so this is the
  # second half of that guard: whatever reaches a terminal here is printable,
  # and an ANSI-laden device name can never redraw the approval prompt.
  defp safe_field(value) do
    value
    |> String.replace(~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u, " ")
    |> String.slice(0, 128)
  end

  # `:device_disconnected` is the daemon's approval-time liveness refusal; the
  # ceremony has to start over because the phone never learned its device id.
  defp format_reason("device_disconnected"), do: "phone disconnected — re-run pairing"

  # The mobile channel is feature-flagged and has no setup surface — neither
  # `fermix setup` nor the web setup can turn it on — so the refusal names the
  # one thing that does.
  defp format_reason("mobile_disabled"), do: mobile_disabled_message()
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp mobile_disabled_message do
    "the mobile channel is off — set `enabled = true` under `[fermix_channels.mobile]` " <>
      "in config.toml, then run `fermix restart`"
  end
end
