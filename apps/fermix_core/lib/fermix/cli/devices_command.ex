defmodule Fermix.CLI.DevicesCommand do
  @moduledoc """
  Lists and revokes daemon-owned mobile device pairings.

  Both operations require the running daemon so persistence and live socket
  revocation have one authority.
  """

  alias Fermix.CLI.Daemon.Client

  @call_timeout_ms 5_000
  @uuid_pattern ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/

  @type request_fun :: (String.t(), map(), pos_integer() ->
                          {:ok, map()} | {:error, term()})

  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    io = io_devices(opts)
    request = request_fun(opts)

    case argv do
      ["list"] -> list_devices(request, io)
      ["revoke", device_id] -> revoke_device(device_id, request, io)
      _ -> usage(io)
    end
  end

  defp list_devices(request, io) do
    case rpc(request, "mobile_devices_list", %{}) do
      {:ok, %{"devices" => devices}} when is_list(devices) -> print_devices(devices, io)
      {:ok, _other} -> fail(io, "fermix devices: invalid device-list reply")
      {:error, :not_running} -> daemon_not_running(io)
      {:error, reason} -> fail(io, "fermix devices list: #{format_reason(reason)}")
    end
  end

  defp revoke_device(device_id, request, io) do
    if Regex.match?(@uuid_pattern, device_id) do
      revoke_valid_device(String.downcase(device_id), request, io)
    else
      invalid_id(io)
    end
  end

  defp revoke_valid_device(device_id, request, io) do
    case rpc(request, "mobile_device_revoke", %{"device_id" => device_id}) do
      {:ok, %{"device_id" => ^device_id}} ->
        IO.puts(io.stdout, "revoked mobile device #{device_id}")
        0

      {:ok, _other} ->
        fail(io, "fermix devices revoke: invalid daemon reply")

      {:error, :not_running} ->
        daemon_not_running(io)

      {:error, reason} ->
        fail(io, "fermix devices revoke: #{format_reason(reason)}")
    end
  end

  defp print_devices([], io) do
    IO.puts(io.stdout, "no paired mobile devices")
    0
  end

  defp print_devices(devices, io) do
    with {:ok, rows} <- validate_rows(devices) do
      IO.puts(io.stdout, "DEVICE ID\tNAME\tCREATED\tLAST SEEN")

      Enum.each(rows, fn row ->
        IO.puts(
          io.stdout,
          Enum.join([row.device_id, row.name, row.created_at, row.last_seen], "\t")
        )
      end)

      0
    else
      {:error, reason} -> fail(io, "fermix devices list: #{format_reason(reason)}")
    end
  end

  defp validate_rows(devices) do
    Enum.reduce_while(devices, {:ok, []}, fn device, {:ok, rows} ->
      case device_row(device) do
        {:ok, row} -> {:cont, {:ok, [row | rows]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp device_row(device) when is_map(device) do
    with {:ok, device_id} <- valid_device_id(Map.get(device, "device_id")),
         name when is_binary(name) and name != "" <- Map.get(device, "name"),
         created when is_binary(created) and created != "" <- Map.get(device, "created_at"),
         {:ok, last_seen} <- optional_time(Map.get(device, "last_seen")) do
      {:ok,
       %{
         device_id: device_id,
         name: safe_field(name),
         created_at: safe_field(created),
         last_seen: safe_field(last_seen)
       }}
    else
      _ -> {:error, :invalid_device_row}
    end
  end

  defp device_row(_device), do: {:error, :invalid_device_row}

  defp valid_device_id(value) when is_binary(value) do
    if Regex.match?(@uuid_pattern, value), do: {:ok, String.downcase(value)}, else: :error
  end

  defp valid_device_id(_value), do: :error
  defp optional_time(nil), do: {:ok, "never"}
  defp optional_time(value) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_time(_value), do: :error

  defp safe_field(value) do
    value
    |> String.replace(~r/[\x00-\x1F\x7F]/u, " ")
    |> String.slice(0, 128)
  end

  defp rpc(request, method, params) do
    case request.(method, params, @call_timeout_ms) do
      {:ok, %{"status" => "ok", "result" => result}} when is_map(result) -> {:ok, result}
      {:ok, %{"status" => "error", "reason" => reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_daemon_reply, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_fun(opts) do
    Keyword.get(opts, :request, fn method, params, timeout ->
      Client.request(method, params: params, timeout: timeout)
    end)
  end

  defp io_devices(opts) do
    %{
      stdout: Keyword.get(opts, :stdout, :stdio),
      stderr: Keyword.get(opts, :stderr, :stderr)
    }
  end

  defp invalid_id(io) do
    IO.puts(io.stderr, "fermix devices revoke: expected a valid device UUID")
    2
  end

  defp usage(io) do
    IO.puts(io.stderr, "usage: fermix devices list")
    IO.puts(io.stderr, "       fermix devices revoke <device_id>")
    2
  end

  defp daemon_not_running(io) do
    fail(io, "Fermix daemon is not running — start it with `fermix start`, then retry")
  end

  defp fail(io, message) do
    IO.puts(io.stderr, message)
    1
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
