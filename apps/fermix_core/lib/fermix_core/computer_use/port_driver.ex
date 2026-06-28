defmodule FermixCore.ComputerUse.PortDriver do
  @moduledoc """
  The production `ComputerUse.Driver`: an Elixir Port to the vendored OS-driver
  sidecar binary (docs/design/COMPUTER_USE.md §5). One newline-delimited JSON
  request to the sidecar's stdin, one newline-delimited JSON response back.

  Only the Port plumbing lives here and is unit-tested against a benign fake echo
  sidecar; the REAL Rust `enigo`+`xcap` binary (actual screen capture + input
  injection + macOS TCC) is Phase-1e and needs real-Mac verification — it is NOT
  shipped or claimed here. `start/1` fails loud if the configured binary is absent
  rather than degrading.

  Framing note: the design says "line-framed JSON". A base64 screenshot response
  can be multiple MB, so this reader sets a large line limit and still accumulates
  `:noeol` fragments up to a hard cap — newline-delimited (JSON has no embedded
  newlines) but robust to large single responses.
  """

  @behaviour FermixCore.ComputerUse.Driver

  alias FermixCore.ComputerUse.Protocol
  alias FermixCore.Timeouts

  require Logger

  @max_response_bytes 16_777_216

  @impl true
  def start(opts) do
    path = Keyword.fetch!(opts, :binary_path)

    if File.regular?(path) do
      port = Port.open({:spawn_executable, path}, port_options(opts))
      # session_id (optional) rides in the driver state so a sidecar-action
      # timeout firing in receive_response/2 can correlate via Timeouts.expired/3.
      {:ok, %{port: port, session_id: Keyword.get(opts, :session_id)}}
    else
      {:error, {:sidecar_missing, path}}
    end
  end

  @impl true
  def execute(%{port: port} = state, request) when is_map(request) do
    Port.command(port, Protocol.encode_request(request))
    receive_response(port, Map.get(state, :session_id))
  rescue
    # Port.command raises if the port is already closed (sidecar died).
    ArgumentError -> {:error, :sidecar_unavailable}
  end

  @impl true
  def stop(%{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp port_options(opts) do
    [
      {:line, @max_response_bytes},
      :binary,
      :exit_status,
      :use_stdio,
      {:args, Keyword.get(opts, :args, [])},
      {:env, Keyword.get(opts, :env, [])}
    ]
  end

  defp receive_response(port, session_id, acc \\ [], size \\ 0) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        Protocol.decode_response(IO.iodata_to_binary([acc, chunk]))

      {^port, {:data, {:noeol, chunk}}} ->
        accumulate(port, session_id, acc, size, chunk)

      {^port, {:exit_status, status}} ->
        {:error, {:sidecar_exited, status}}
    after
      Timeouts.cu_sidecar_action() ->
        ms = Timeouts.cu_sidecar_action()
        Timeouts.expired(:cu_sidecar_action, ms, %{session_id: session_id})
    end
  end

  defp accumulate(port, session_id, acc, size, chunk) do
    new_size = size + byte_size(chunk)

    if new_size > @max_response_bytes do
      {:error, :sidecar_response_too_large}
    else
      receive_response(port, session_id, [acc, chunk], new_size)
    end
  end
end
