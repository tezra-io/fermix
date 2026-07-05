defmodule FermixCore.ComputerUse.PortDriver do
  @moduledoc """
  The production computer-use `Driver`: a thin fermix adapter over
  `Compux.PortDriver` (the crash-isolated Rust sidecar spawned over a Port).

  compux owns the MECHANISM — transport framing, coordinate math, the wire
  protocol. This adapter adds fermix POLICY on top:

    * **version handshake** — `start/1` performs the `hello` round-trip and refuses
      a sidecar whose `protocol_version` differs from
      `Compux.Protocol.protocol_version/0`, so the compiled-in encoder and the
      separately-installed binary can never silently drift.
    * **timeout telemetry** — a sidecar-action timeout is surfaced through the
      centralized `Timeouts.expired/3` (correlated by `:session_id`) and returns the
      `{:error, {:timeout, :cu_sidecar_action, ms}}` shape the `Session` poison-resets
      on. compux itself stays policy-free and only returns `{:error, {:timeout, ms}}`.

  The state keeps `:port` at the top level so the owning `Session`'s `handle_info`
  can match stale-response / exit-status messages by port.
  """

  @behaviour Compux.Driver

  alias FermixCore.Timeouts

  @impl true
  def start(opts) do
    path = Keyword.fetch!(opts, :binary_path)

    compux_opts = [
      binary_path: path,
      timeout: Keyword.get(opts, :timeout, Timeouts.cu_sidecar_action()),
      args: Keyword.get(opts, :args, []),
      env: Keyword.get(opts, :env, [])
    ]

    with {:ok, cstate} <- Compux.PortDriver.start(compux_opts),
         :ok <- handshake(cstate) do
      {:ok, Map.put(cstate, :session_id, Keyword.get(opts, :session_id))}
    end
  end

  @impl true
  def execute(state, request) when is_map(request) do
    case Compux.PortDriver.execute(state, request) do
      {:error, {:timeout, ms}} ->
        Timeouts.expired(:cu_sidecar_action, ms, %{session_id: state.session_id})

      other ->
        other
    end
  end

  @impl true
  def stop(state), do: Compux.PortDriver.stop(state)

  # One hello round-trip: refuse a binary whose wire version we don't speak, and
  # tear the freshly-started sidecar down on refusal so no orphaned Port leaks.
  defp handshake(cstate) do
    ours = Compux.Protocol.protocol_version()

    case Compux.PortDriver.execute(cstate, %{"action" => "hello"}) do
      {:ok, %{"protocol_version" => ^ours}} ->
        :ok

      {:ok, %{"protocol_version" => theirs}} ->
        Compux.PortDriver.stop(cstate)
        {:error, {:protocol_mismatch, %{library: ours, sidecar: theirs}}}

      {:ok, _other} ->
        Compux.PortDriver.stop(cstate)
        {:error, {:protocol_mismatch, %{library: ours, sidecar: nil}}}

      {:error, reason} ->
        Compux.PortDriver.stop(cstate)
        {:error, reason}
    end
  end
end
