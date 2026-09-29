defmodule Fermix.CLI.PairCommand do
  @moduledoc """
  Pairs one phone with the running daemon over the management protocol.

  The daemon owns the listener, the one-time pairing window and device
  persistence; this command never reads or writes the pairing store itself. It
  opens the window with `mobile.pair.start`, prints the QR code for the link the
  daemon returns once, polls `mobile.pair.get` until a phone asks, confirms the
  six-digit code with the operator, and answers with `mobile.pair.decide`. Any
  failure after the window opened closes it through `mobile.pair.cancel` before
  the command exits, so a broken run never leaves a window waiting for a scan.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.TerminalQR
  alias FermixCore.Management.Mobile

  @call_timeout_ms 5_000
  @poll_interval_ms 1_000
  # Slack beyond the window's own time. The daemon closes the window on its own
  # clock; this only bounds how long the command waits for it to say so.
  @poll_slack_ms 5_000
  # The daemon's pairing window never runs longer than this, so a longer one is
  # a reply this command refuses rather than a loop it follows.
  @max_window_ms 120_000
  @max_uri_bytes 2_048
  @max_text_bytes 128
  @session_id_pattern ~r/^[A-Za-z0-9_-]{1,128}$/
  @sas_pattern ~r/^\d{6}$/
  @uuid_pattern ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  @control_chars ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @uri_prefix "fermix://pair?"

  @type client :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})

  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    io = io_devices(opts)

    case argv do
      [] -> pair(io, deps(opts))
      _ -> usage(io)
    end
  end

  defp pair(io, deps) do
    case call(deps, "mobile.pair.start", %{}) do
      {:ok, %{"state" => "failed"} = view} -> refused_start(view, io)
      {:ok, view} -> opened(view, io, deps)
      {:error, reason} -> start_error(reason, io)
    end
  end

  # Nothing was opened, so there is nothing to cancel.
  defp refused_start(%{"failure" => %{"sentence" => sentence}}, io) when is_binary(sentence) do
    IO.puts(io.stderr, "fermix pair: #{scrub(sentence)}")
    if sentence == Mobile.off_sentence(), do: IO.puts(io.stderr, enable_hint())
    1
  end

  defp refused_start(_view, io),
    do: fail(io, "fermix pair: the daemon answered an invalid pairing refusal")

  defp start_error(:not_running, io), do: daemon_not_running(io)

  defp start_error({:management_error, "busy", _message, _details}, io),
    do: fail(io, "fermix pair: a pairing window is already open")

  defp start_error(reason, io), do: fail(io, "fermix pair: #{describe(reason)}")

  defp opened(view, io, deps) do
    session_id = Map.get(view, "session_id")

    if valid_session_id?(session_id) do
      run_session(session_id, view, io, deps)
    else
      fail(io, "fermix pair: the daemon answered an invalid pairing window")
    end
  end

  defp run_session(session_id, view, io, deps) do
    result =
      with {:ok, ttl_ms} <- show_window(view, io),
           {:ok, current} <- await_phone(session_id, max_polls(ttl_ms), deps),
           {:ok, final} <- decide_if_asked(current, session_id, io, deps) do
        print_outcome(final, io)
      end

    case result do
      status when is_integer(status) -> status
      {:error, reason} -> cancel_and_fail(session_id, reason, io, deps)
    end
  end

  defp show_window(view, io) do
    with {:ok, uri} <- pairing_uri(Map.get(view, "uri")),
         {:ok, ttl_ms} <- window_ttl(Map.get(view, "ttl_ms")),
         {:ok, qr} <- TerminalQR.render(uri) do
      seconds = div(ttl_ms + 999, 1_000)
      IO.puts(io.stdout, "Scan this QR code in the Fermix phone app (expires in #{seconds}s):")
      IO.puts(io.stdout, qr)
      IO.puts(io.stdout, "Manual pairing URI: #{uri}")
      {:ok, ttl_ms}
    end
  end

  defp pairing_uri(uri)
       when is_binary(uri) and byte_size(uri) <= @max_uri_bytes do
    if String.starts_with?(uri, @uri_prefix) and not Regex.match?(@control_chars, uri),
      do: {:ok, uri},
      else: {:error, :invalid_pairing_window}
  end

  defp pairing_uri(_uri), do: {:error, :invalid_pairing_window}

  defp window_ttl(ttl_ms) when is_integer(ttl_ms) and ttl_ms in 1..@max_window_ms,
    do: {:ok, ttl_ms}

  defp window_ttl(_ttl_ms), do: {:error, :invalid_pairing_window}

  defp max_polls(ttl_ms),
    do: div(ttl_ms + @poll_slack_ms + @poll_interval_ms - 1, @poll_interval_ms)

  # Polls until the session leaves `awaiting_scan`: a phone asked, or the
  # window closed on its own.
  defp await_phone(_session_id, 0 = _remaining, _deps), do: {:error, :pairing_window_unfinished}

  defp await_phone(session_id, remaining, deps) do
    deps.sleep.(@poll_interval_ms)

    case call(deps, "mobile.pair.get", %{"session_id" => session_id}) do
      {:ok, %{"state" => "awaiting_scan"}} -> await_phone(session_id, remaining - 1, deps)
      {:ok, view} -> {:ok, view}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decide_if_asked(%{"state" => "awaiting_decision"} = view, session_id, io, deps) do
    with {:ok, request} <- pairing_request(Map.get(view, "request")) do
      approved? = prompt_approval(request, io)
      params = %{"session_id" => session_id, "approved" => approved?}

      case call(deps, "mobile.pair.decide", params) do
        {:ok, %{"state" => state}} when state in ["awaiting_scan", "awaiting_decision"] ->
          {:error, :invalid_pairing_session}

        other ->
          other
      end
    end
  end

  defp decide_if_asked(view, _session_id, _io, _deps), do: {:ok, view}

  defp pairing_request(%{"sas" => sas, "attestation" => %{"sentence" => sentence}} = request)
       when is_binary(sas) and is_binary(sentence) do
    valid? =
      valid_text?(Map.get(request, "device_name")) and
        valid_text?(Map.get(request, "model")) and
        Regex.match?(@sas_pattern, sas)

    if valid?, do: {:ok, request}, else: {:error, :invalid_pairing_request}
  end

  defp pairing_request(_request), do: {:error, :invalid_pairing_request}

  # The human is the comparator: approve only when the phone shows the same
  # six digits. A blank answer or a closed input denies.
  defp prompt_approval(request, io) do
    IO.puts(io.stdout, scrub(request["attestation"]["sentence"]))

    prompt =
      "#{safe_field(request["model"])} '#{safe_field(request["device_name"])}' requests " <>
        "pairing. Phone shows #{request["sas"]}. Approve? [y/N] "

    IO.write(io.stdout, prompt)

    case IO.gets(io.stdin, "") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      :eof -> false
      {:error, _reason} -> false
    end
  end

  defp print_outcome(
         %{
           "state" => "approved",
           "outcome" => %{"device_id" => device_id},
           "request" => %{"device_name" => name}
         },
         io
       )
       when is_binary(name) and name != "" do
    case valid_device_id(device_id) do
      {:ok, device_id} ->
        IO.puts(io.stdout, "\npaired #{safe_field(name)} (#{device_id})")
        0

      :error ->
        {:error, :invalid_pairing_session}
    end
  end

  defp print_outcome(%{"state" => "denied"}, io) do
    IO.puts(io.stdout, "\npairing denied")
    0
  end

  defp print_outcome(%{"state" => "failed", "failure" => %{"sentence" => sentence}}, io)
       when is_binary(sentence),
       do: fail(io, "fermix pair: #{scrub(sentence)}")

  defp print_outcome(%{"state" => state, "outcome" => %{"reason" => reason}}, io)
       when state in ["expired", "cancelled"] and is_binary(reason),
       do: fail(io, "fermix pair: pairing ended (#{scrub(reason)})")

  defp print_outcome(_view, _io), do: {:error, :invalid_pairing_session}

  defp cancel_and_fail(session_id, reason, io, deps) do
    case call(deps, "mobile.pair.cancel", %{"session_id" => session_id}) do
      {:ok, %{"state" => _state}} -> fail(io, "fermix pair: #{describe(reason)}")
      {:ok, _other} -> fail(io, cleanup_error(reason, :invalid_pairing_session))
      {:error, cancel_reason} -> fail(io, cleanup_error(reason, cancel_reason))
    end
  end

  defp cleanup_error(reason, cancel_reason) do
    "fermix pair: #{describe(reason)}; pairing cleanup failed: #{describe(cancel_reason)}"
  end

  defp call(deps, method, params), do: deps.client.(method, params, timeout: @call_timeout_ms)

  # A management refusal that carries the daemon's own sentence says more than
  # its code does, so the sentence is what the operator reads.
  defp describe({:management_error, _code, _message, %{"sentence" => sentence}})
       when is_binary(sentence),
       do: scrub(sentence)

  defp describe({:management_error, "unavailable", _message, %{"capability" => "mobile"}}),
    do: "the phone channel is not running; `fermix doctor` says why"

  defp describe(:not_running), do: "the daemon stopped answering"
  defp describe(:pairing_window_unfinished), do: "the daemon never closed the pairing window"
  defp describe(:invalid_pairing_window), do: "the daemon answered an invalid pairing window"
  defp describe(:invalid_pairing_request), do: "the daemon answered an invalid pairing request"
  defp describe(:invalid_pairing_session), do: "the daemon answered an invalid pairing session"
  defp describe({:qr_generation_failed, _reason}), do: "the QR code could not be drawn"
  defp describe(reason), do: reason |> Client.describe_error() |> scrub()

  defp deps(opts) do
    %{
      client: Keyword.get(opts, :client, &Client.request_v1/3),
      sleep: Keyword.get(opts, :poll_sleep, &Process.sleep/1)
    }
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

  # The phone channel's switch on a host managed without the desktop app.
  defp enable_hint do
    "set `enabled = true` under `[fermix_channels.mobile]` in config.toml, " <>
      "then run `fermix restart`"
  end

  defp valid_session_id?(value),
    do: is_binary(value) and Regex.match?(@session_id_pattern, value)

  defp valid_device_id(value) when is_binary(value) do
    if Regex.match?(@uuid_pattern, value), do: {:ok, String.downcase(value)}, else: :error
  end

  defp valid_device_id(_value), do: :error

  defp valid_text?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= @max_text_bytes

  # The daemon refuses control characters at pairing intake, so this is the
  # second half of that guard: whatever reaches a terminal here is printable,
  # and an ANSI-laden device name can never redraw the approval prompt.
  defp safe_field(value), do: value |> scrub() |> String.slice(0, @max_text_bytes)

  defp scrub(value), do: String.replace(value, @control_chars, " ")
end
