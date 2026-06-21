defmodule FermixCore.ComputerUse.Session do
  @moduledoc """
  A supervised, per-conversation computer-use session: it owns the long-lived
  OS-driver backend (the Port to the sidecar) across many actions, enforces the
  §7 safety floor and the §6 action budget, and emits the `cua_<id>` lifecycle
  telemetry (docs/design/COMPUTER_USE.md §5–§9).

  The blocking human-in-the-loop confirmation deliberately does NOT live in this
  GenServer: `classify/2` is a fast, non-blocking decision (validate + budget +
  gate), and the caller (the tool, running in the agent-loop tool task) resolves
  any confirmation in its OWN process before calling `execute/2`. That keeps a
  pending confirmation off the session's mailbox, so `/stop` / pet-interrupt
  teardown (which kills the tool task and this session) is never queued behind a
  blocked call.

  `terminate/2` always stops the driver (releasing held input) — the load-bearing
  teardown guarantee — and emits the lifecycle bookend.
  """

  use GenServer

  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Protocol
  alias FermixCore.ComputerUse.Safety
  alias FermixCore.ComputerUse.Telemetry

  require Logger

  @execute_timeout_ms 30_000

  @type action_result :: %{summary: String.t(), image: map() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Classify an action without executing or blocking: validate it (Protocol), check
  the per-session action budget, and apply the §7.3 gate. Returns the finalized
  request (display default + post-action screenshot filled from config) so the
  caller can `execute/2` it after resolving any confirmation.
  """
  @spec classify(GenServer.server(), map()) ::
          {:ok, :auto, map()}
          | {:ok, :confirm, map(), String.t()}
          | {:error, term()}
  def classify(server, action_params) when is_map(action_params) do
    GenServer.call(server, {:classify, action_params})
  end

  @doc "Run a finalized request through the driver; increments the action count."
  @spec execute(GenServer.server(), map()) :: {:ok, action_result()} | {:error, term()}
  def execute(server, request) when is_map(request) do
    GenServer.call(server, {:execute, request}, @execute_timeout_ms)
  end

  @doc "Actions issued so far this session."
  @spec action_count(GenServer.server()) :: non_neg_integer()
  def action_count(server), do: GenServer.call(server, :action_count)

  @doc "Tear the session down — stops the driver (releasing held input) and emits the lifecycle bookend."
  @spec abort(GenServer.server()) :: :ok
  def abort(server), do: GenServer.stop(server, :normal)

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    origin = Keyword.get(opts, :origin, :interactive)
    {driver_mod, driver_opts} = Keyword.fetch!(opts, :driver)

    with :ok <- ensure_host_start_allowed(config, origin),
         {:ok, driver_state} <- driver_mod.start(driver_opts) do
      Process.flag(:trap_exit, true)

      state = %{
        config: config,
        origin: origin,
        driver_mod: driver_mod,
        driver_state: driver_state,
        action_count: 0,
        session_id: Keyword.get(opts, :session_id) || mint_session_id(),
        parent_session: Keyword.get(opts, :parent_session),
        agent: Keyword.get(opts, :agent, "computer_use"),
        started_at: now_ms()
      }

      Telemetry.session_start(meta(state))
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:classify, params}, _from, state) do
    result =
      with {:ok, request} <- Protocol.validate(params),
           :ok <- check_budget(state) do
        finalized = finalize_request(request, state.config)

        case Safety.gate(request["action"], state.config) do
          :auto -> {:ok, :auto, finalized}
          :confirm -> {:ok, :confirm, finalized, describe(request)}
        end
      end

    {:reply, result, state}
  end

  def handle_call({:execute, request}, _from, state) do
    case check_budget(state) do
      :ok ->
        run_action(request, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:action_count, _from, state), do: {:reply, state.action_count, state}

  @impl true
  def terminate(reason, state) do
    state.driver_mod.stop(state.driver_state)
    emit_lifecycle_end(reason, state)
    :ok
  end

  defp run_action(request, state) do
    case state.driver_mod.execute(state.driver_state, request) do
      {:ok, response} ->
        state = %{state | action_count: state.action_count + 1}

        case normalize_response(response) do
          {:ok, result} -> {:reply, {:ok, result}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # Host mode against a real session may only start from an attended owner origin
  # (§7.6); browser mode (fresh context) accepts any origin.
  defp ensure_host_start_allowed(%Config{mode: :host}, origin) do
    if Safety.host_start_allowed?(origin), do: :ok, else: {:error, {:host_start_refused, origin}}
  end

  defp ensure_host_start_allowed(%Config{}, _origin), do: :ok

  defp check_budget(state) do
    if Safety.within_action_budget?(state.action_count, state.config),
      do: :ok,
      else: {:error, :action_budget_exhausted}
  end

  defp finalize_request(request, %Config{} = config) do
    request
    |> Map.put_new("display", config.display)
    |> put_screenshot_after(config)
  end

  defp put_screenshot_after(request, config) do
    if Protocol.read_only?(request["action"]),
      do: request,
      else: Map.put(request, "screenshot_after", config.screenshot_after?)
  end

  # A response carrying base64 image bytes becomes an image content part (the
  # Phase-0 success_with_images path); a bare ack becomes a short text summary.
  # Invalid base64 from the sidecar fails loud rather than shipping garbage.
  defp normalize_response(%{"data" => data, "mime" => mime} = response)
       when is_binary(data) and is_binary(mime) do
    case Base.decode64(data) do
      {:ok, bytes} ->
        {:ok,
         %{
           summary: screenshot_summary(response),
           image: %{type: :image, mime_type: mime, data: bytes}
         }}

      :error ->
        {:error, "sidecar returned an invalid base64 screenshot"}
    end
  end

  defp normalize_response(_response), do: {:ok, %{summary: "ok", image: nil}}

  defp screenshot_summary(response) do
    case {response["width"], response["height"]} do
      {w, h} when is_integer(w) and is_integer(h) ->
        "screenshot #{w}x#{h} (display #{response["display"] || 0})"

      _ ->
        "screenshot captured"
    end
  end

  defp describe(request) do
    case request["action"] do
      "type" -> ~s(type text)
      "key" -> "key " <> to_string(request["chord"])
      action -> action
    end
  end

  defp emit_lifecycle_end(reason, state) do
    measurements = %{actions: state.action_count, duration_ms: now_ms() - state.started_at}

    case reason do
      :normal -> Telemetry.session_complete(meta(state), measurements)
      :shutdown -> Telemetry.session_complete(meta(state), measurements)
      {:shutdown, _} -> Telemetry.session_complete(meta(state), measurements)
      other -> Telemetry.session_error(meta(state), other)
    end
  end

  defp meta(state) do
    %{
      session_id: state.session_id,
      parent_session: state.parent_session,
      agent: state.agent,
      mode: state.config.mode,
      origin: state.origin
    }
  end

  defp mint_session_id do
    "cua_" <> (9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
