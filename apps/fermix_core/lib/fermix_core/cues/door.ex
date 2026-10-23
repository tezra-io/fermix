defmodule FermixCore.Cues.Door do
  @moduledoc """
  The cue door's lifecycle owner (M60 §6.7): a Bandit listener bound to
  `127.0.0.1` on `[fermix_core.cues] door_port` (default 4032), serving
  `Cues.Door.Router` and nothing else.

  A port it cannot listen on (another program holds it) leaves the door
  unavailable, never stopped: a stop would escalate through `Cues.Supervisor`.
  It logs why, says so through `status/1`, retries from one second doubling to
  a minute, and gives up after a day until the next boot. A Bandit that dies
  while serving is retried the same way (the phone listener's approach,
  `FermixChannels.Mobile.Listener`).

  It also writes the door's coalesced reject counts: every 10 seconds it takes
  the counts `Cues.Buckets` holds and writes one row update per source, so a
  flood of refused requests is one write, not one per request.
  """

  use GenServer

  require Logger

  alias FermixCore.Cues.Buckets
  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Door.Router
  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.CuesSql

  @bind {127, 0, 0, 1}
  # Pushers are few: a handful of scripts and machines. The body bounds are
  # the router's; these bound idle and slow connections before a request.
  @num_acceptors 4
  @num_connections 64
  @read_timeout_ms 10_000
  @http_1_options [
    max_request_line_length: 2_048,
    max_header_length: 8_192,
    max_header_count: 64
  ]
  @first_retry_ms 1_000
  @max_retry_ms 60_000
  @retry_window_ms 24 * 3_600_000
  @reject_flush_ms 10_000
  # How deep `failure/1` looks into a nested start error for the socket errno.
  @max_reason_depth 8

  @type failure :: :address_unavailable | :address_in_use | :permission_denied | :listen_failed
  @type status ::
          {:listening, {:inet.ip_address(), :inet.port_number()}} | {:unavailable, failure()}

  @doc """
  Options: `:port` (default `Cues.Config.door_port/0`; 0 picks a free port),
  `:router_opts` (passed to the router), `:clock` (monotonic ms),
  `:now` (zero-arity, a `DateTime`), `:schedule` (`(message, ms) -> term`),
  `:reject_writer` (`(ref, counts, now) -> :ok | {:error, term}`; default: one
  `{:source_reject, ...}` request to `:repo`, default `Memory.Repo`), `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Listening with its address (port 0 resolved), or unavailable with the reason."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Writes the coalesced reject counts now, as the 10 s timer does."
  @spec flush_rejects(GenServer.server()) :: :ok
  def flush_rejects(server \\ __MODULE__), do: GenServer.call(server, :flush_rejects)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      bandit: nil,
      failure: nil,
      retry: nil,
      port: Keyword.get_lazy(opts, :port, &Config.door_port/0),
      router_opts: Keyword.get(opts, :router_opts, []),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      schedule: Keyword.get(opts, :schedule, &Process.send_after(self(), &1, &2)),
      reject_writer:
        Keyword.get_lazy(opts, :reject_writer, fn ->
          rejects_to(Keyword.get(opts, :repo, Repo))
        end)
    }

    _timer = state.schedule.(:flush_rejects, @reject_flush_ms)

    case start_bandit(state) do
      {:ok, bandit} -> {:ok, %{state | bandit: bandit}}
      {:error, reason} -> {:ok, begin_retries(state, reason)}
    end
  end

  @impl true
  def handle_call(:status, _from, %{bandit: nil} = state),
    do: {:reply, {:unavailable, state.failure}, state}

  def handle_call(:status, _from, state) do
    case ThousandIsland.listener_info(state.bandit) do
      {:ok, address} -> {:reply, {:listening, address}, state}
      :error -> {:reply, {:unavailable, :listen_failed}, state}
    end
  end

  def handle_call(:flush_rejects, _from, state), do: {:reply, flush(state), state}

  @impl true
  def handle_info(:flush_rejects, state) do
    :ok = flush(state)
    _timer = state.schedule.(:flush_rejects, @reject_flush_ms)
    {:noreply, state}
  end

  def handle_info({:EXIT, bandit, reason}, %{bandit: bandit} = state) do
    Logger.error("cue door stopped serving (#{inspect(reason)}); retrying")
    {:noreply, begin_retries(%{state | bandit: nil}, {:listener_exited, reason})}
  end

  def handle_info({:retry_listen, token}, %{retry: %{token: token}} = state) do
    {:noreply, retry_listen(state)}
  end

  # A failed `Bandit.start_link` also sends its exit, and a superseded retry
  # timer its message: neither concerns the current listener.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{bandit: bandit}) when is_pid(bandit) do
    if Process.alive?(bandit), do: Supervisor.stop(bandit, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- listener --------------------------------------------------------------

  defp start_bandit(state) do
    Bandit.start_link(
      scheme: :http,
      ip: @bind,
      port: state.port,
      plug: {Router, state.router_opts},
      startup_log: false,
      thousand_island_options: [
        num_acceptors: @num_acceptors,
        num_connections: @num_connections,
        read_timeout: @read_timeout_ms
      ],
      http_1_options: @http_1_options,
      http_2_options: [enabled: false],
      websocket_options: [enabled: false]
    )
  end

  # The retry window is measured from the first failure of a run of them, so a
  # door that keeps failing gives up a day after it stopped serving.
  defp begin_retries(state, reason) do
    Logger.error(
      "cue door could not listen on 127.0.0.1:#{state.port} (#{inspect(reason)}); retrying"
    )

    retry = %{
      deadline_ms: state.clock.() + @retry_window_ms,
      delay_ms: @first_retry_ms,
      token: nil
    }

    arm_retry(%{state | failure: failure(reason), retry: retry})
  end

  defp arm_retry(%{retry: retry} = state) do
    token = make_ref()
    _timer = state.schedule.({:retry_listen, token}, retry.delay_ms)
    %{state | retry: %{retry | token: token}}
  end

  defp retry_listen(%{retry: retry} = state) do
    if state.clock.() >= retry.deadline_ms do
      Logger.error(
        "cue door stopped retrying after a day without serving (#{state.failure}); " <>
          "it stays unavailable until Fermix restarts"
      )

      %{state | retry: nil}
    else
      attempt_listen(state)
    end
  end

  defp attempt_listen(state) do
    case start_bandit(state) do
      {:ok, bandit} ->
        Logger.info("cue door is serving again")
        %{state | bandit: bandit, failure: nil, retry: nil}

      {:error, reason} ->
        Logger.warning("cue door retry failed (#{inspect(reason)})")
        delay = min(state.retry.delay_ms * 2, @max_retry_ms)
        arm_retry(%{state | failure: failure(reason), retry: %{state.retry | delay_ms: delay}})
    end
  end

  # The errno is buried in whichever supervisor or listener tuple reported it.
  defp failure(reason) do
    cond do
      mentions?(reason, :eaddrnotavail, @max_reason_depth) -> :address_unavailable
      mentions?(reason, :eaddrinuse, @max_reason_depth) -> :address_in_use
      mentions?(reason, :eacces, @max_reason_depth) -> :permission_denied
      true -> :listen_failed
    end
  end

  defp mentions?(atom, atom, _depth), do: true
  defp mentions?(_term, _atom, 0), do: false

  defp mentions?(term, atom, depth) when is_tuple(term),
    do: term |> Tuple.to_list() |> mentions?(atom, depth)

  defp mentions?(term, atom, depth) when is_list(term),
    do: Enum.any?(term, &mentions?(&1, atom, depth - 1))

  defp mentions?(_term, _atom, _depth), do: false

  # --- reject counts ---------------------------------------------------------

  # A failed write loses those counts, which are only counts; it is logged.
  defp flush(state) do
    now = state.now.()

    Enum.each(Buckets.take_rejects(), fn {ref, counts} ->
      counts = Map.new(counts, fn {reason, count} -> {Atom.to_string(reason), count} end)

      case state.reject_writer.(ref, counts, now) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "cue door: reject counts for #{ref} were not written (#{inspect(reason)})"
          )
      end
    end)
  end

  defp rejects_to(repo) do
    fn ref, counts, now ->
      case Repo.cues_call(CuesSql, {:source_reject, ref, counts, now}, server: repo) do
        {:ok, _counts} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
