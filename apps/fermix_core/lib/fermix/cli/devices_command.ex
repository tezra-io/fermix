defmodule Fermix.CLI.DevicesCommand do
  @moduledoc """
  Lists and revokes the phones paired with the running daemon, over the
  management protocol (`mobile.devices.list`, `mobile.devices.revoke`).

  Both operations require the running daemon so persistence and live socket
  revocation have one authority.
  """

  alias Fermix.CLI.Daemon.Client

  @call_timeout_ms 5_000
  @uuid_pattern ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
  @control_chars ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u

  @type client :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})

  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, opts \\ []) when is_list(argv) and is_list(opts) do
    io = io_devices(opts)
    client = Keyword.get(opts, :client, &Client.request_v1/3)

    case argv do
      ["list"] -> list_devices(client, io)
      ["revoke", device_id] -> revoke_device(device_id, client, io)
      _ -> usage(io)
    end
  end

  defp list_devices(client, io) do
    case client.("mobile.devices.list", %{}, timeout: @call_timeout_ms) do
      {:ok, %{"devices" => devices}} when is_list(devices) -> print_devices(devices, io)
      {:ok, _other} -> fail(io, "fermix devices: invalid device-list reply")
      {:error, :not_running} -> daemon_not_running(io)
      {:error, reason} -> fail(io, "fermix devices list: #{describe(reason)}")
    end
  end

  defp revoke_device(device_id, client, io) do
    if Regex.match?(@uuid_pattern, device_id) do
      revoke_valid_device(String.downcase(device_id), client, io)
    else
      invalid_id(io)
    end
  end

  defp revoke_valid_device(device_id, client, io) do
    params = %{"device_id" => device_id}

    case client.("mobile.devices.revoke", params, timeout: @call_timeout_ms) do
      {:ok, %{"device_id" => ^device_id, "revoked" => true}} ->
        IO.puts(io.stdout, "revoked phone #{device_id}")
        0

      {:ok, _other} ->
        fail(io, "fermix devices revoke: invalid daemon reply")

      {:error, :not_running} ->
        daemon_not_running(io)

      {:error, reason} ->
        fail(io, "fermix devices revoke: #{describe(reason)}")
    end
  end

  defp print_devices([], io) do
    IO.puts(io.stdout, "no paired phones")
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
      {:error, :invalid_device_row} -> fail(io, "fermix devices list: invalid device row")
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

  # The wire's `mobileDevice` carries more than these four fields; the table
  # prints only the ones an operator needs to pick a phone to revoke.
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

  # C1 (U+0080–U+009F) belongs in the class alongside C0 and DEL: U+009B is a
  # single-codepoint CSI that a terminal honours exactly like ESC-[.
  defp safe_field(value), do: value |> scrub() |> String.slice(0, 128)
  defp scrub(value), do: String.replace(value, @control_chars, " ")

  # A management refusal that carries the daemon's own sentence says more than
  # its code does, so the sentence is what the operator reads.
  defp describe({:management_error, _code, _message, %{"sentence" => sentence}})
       when is_binary(sentence),
       do: scrub(sentence)

  defp describe({:management_error, "unavailable", _message, %{"capability" => "mobile"}}),
    do: "the phone channel is not running; `fermix doctor` says why"

  defp describe(reason), do: reason |> Client.describe_error() |> scrub()

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
end
