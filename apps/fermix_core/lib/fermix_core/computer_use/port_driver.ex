defmodule FermixCore.ComputerUse.PortDriver do
  @moduledoc """
  The production computer-use `Driver`: a thin fermix adapter over
  `Compux.PortDriver` (the crash-isolated Rust sidecar, reached through
  `Compux.Transport`).

  compux owns the MECHANISM — the Port, the framing, request ids, generations,
  one absolute deadline per request, and the `hello` handshake that refuses a
  sidecar whose wire version is not this build's (`{:protocol_mismatch, …}` from
  `start/1`). This adapter adds exactly one piece of fermix POLICY: a
  sidecar-action timeout is surfaced through the centralized `Timeouts.expired/3`
  (correlated by `:session_id`) and returns the
  `{:error, {:timeout, :cu_sidecar_action, ms}}` shape the `Session`
  poison-resets on. compux itself stays policy-free and only reports
  `{:error, {:timeout, ms}}`.

  `control/2` passes straight through: the transport admits a control whatever is
  in flight, which is what lets `Session` confirm a Pause while its `ActionWorker`
  is blocked inside an action.

  The state is opaque — it holds the transport's pid, not a Port — plus the
  `:session_id` this adapter needs for correlation. The sidecar's death reaches
  the process that called `start/1` as `{:compux_sidecar_exit, transport, status}`.
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

    with {:ok, cstate} <- Compux.PortDriver.start(compux_opts) do
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
  def control(state, action) when action in [:pause, :resume, :release],
    do: Compux.PortDriver.control(state, action)

  @impl true
  def stop(state), do: Compux.PortDriver.stop(state)
end
