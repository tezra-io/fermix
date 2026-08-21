defmodule FermixCore.Meetings.SidecarSource do
  @moduledoc """
  `FermixCore.Meetings.AudioSource` for the Google Meet lane: owns one meetbot
  sidecar and translates its wire frames into the normalized message set the
  Session consumes.

  The translation is 1:1 and total — every control type the protocol defines
  has a clause, and anything else tears the source down with a protocol error.
  A frame the source cannot name is a sidecar speaking a contract this daemon
  does not, and continuing past it would silently drop audio or roster changes
  the transcript is attributed against.

  Two bounded policies live here:

  - **Relaunch once, pre-admission only.** A sidecar that dies before it is in
    the meeting is usually a flaky browser start, so it gets exactly one more
    attempt (`@relaunch_max`). Once admitted, a crash means the bot left a
    meeting that is still running — relaunching would re-announce and rejoin
    behind the operator's back, so it is a terminal source error instead.
  - **Ping only when idle.** After `@ping_idle_ms` with no inbound frame the
    source pings; if no frame of any kind answers within `@pong_grace_ms` the
    sidecar is wedged (a hung Chromium holds the port open indefinitely, so
    silence is the only detectable symptom) and the source fails.
  """

  use GenServer, restart: :temporary

  require Logger

  @behaviour FermixCore.Meetings.AudioSource

  alias FermixCore.Meetings.Sidecar
  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.Timeouts

  @relaunch_max 1
  @roster_max 200

  # Idle/ping bounds (protocol §4.3). The tick is the single timer that drives
  # both; `timers:` in `args` overrides them for tests only.
  @tick_ms 5_000
  @ping_idle_ms 30_000
  @pong_grace_ms 15_000

  @stop_timeout_ms 10_000

  @doc """
  Starts the source for one meeting.

  `args` requires `:url` and `:config` (a `FermixCore.Meetings.Config` struct).
  Optional: `:session_id` (telemetry correlation), and the test seams
  `:sidecar_module`, `:sidecar_opts`, `:binary_path`, `:profile_dir`,
  `:handshake_timeout_ms`, `:timers`.

  Resolving the binary before the process exists keeps "the sidecar is not
  installed" a plain caller-visible error instead of a crash report.
  """
  @impl FermixCore.Meetings.AudioSource
  @spec start_link(pid(), map()) :: {:ok, pid()} | {:error, term()}
  def start_link(session, args) when is_pid(session) and is_map(args) do
    case resolve_binary(args) do
      {:ok, binary_path} -> GenServer.start_link(__MODULE__, {session, args, binary_path})
      {:error, reason} -> {:error, reason}
    end
  end

  @impl FermixCore.Meetings.AudioSource
  @spec leave(pid()) :: :ok
  def leave(source) when is_pid(source), do: GenServer.cast(source, :leave)

  @impl FermixCore.Meetings.AudioSource
  @spec stop(pid()) :: :ok
  def stop(source) when is_pid(source) do
    if Process.alive?(source), do: GenServer.stop(source, :normal, @stop_timeout_ms)
    :ok
  catch
    # Best-effort by contract: the source raced us to its own exit, or it is
    # wedged in the sidecar handshake and outlasted the stop timeout. Either way
    # the caller is a Session in teardown, and its terminal row write — the only
    # record of how the meeting ended — must not die with the source.
    :exit, _reason -> :ok
  end

  @doc "The Meet bot occupies a roster seat of its own, so the Session discounts one."
  @impl FermixCore.Meetings.AudioSource
  @spec self_count() :: non_neg_integer()
  def self_count, do: 1

  @impl GenServer
  def init({session, args, binary_path}) do
    timers = timers(args)
    profile_dir = Map.get(args, :profile_dir, SidecarInstaller.profile_dir())
    Process.send_after(self(), :tick, timers.tick_ms)

    state = %{
      session: session,
      sidecar_mod: Map.get(args, :sidecar_module, Sidecar.Port),
      sidecar: nil,
      launch_opts: launch_opts(args, binary_path, profile_dir),
      join_msg: join_msg(args, profile_dir),
      session_id: Map.get(args, :session_id),
      timers: timers,
      relaunches: 0,
      admitted?: false,
      last_sent_mono: mono(),
      ping_pending?: false,
      ping_sent_mono: nil
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl GenServer
  def handle_continue(:launch, state) do
    case state.sidecar_mod.launch(self(), state.launch_opts) do
      {:ok, sidecar} -> join(%{state | sidecar: sidecar})
      {:error, reason} -> fail(state, launch_error(reason, state.session_id))
    end
  end

  @impl GenServer
  def handle_cast(:leave, state) do
    case state.sidecar_mod.send_control(state.sidecar, %{"type" => "leave"}) do
      :ok -> {:noreply, state}
      {:error, :closed} -> fail(state, {:sidecar_crashed, :closed})
    end
  end

  @impl GenServer
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.timers.tick_ms)
    ping_policy(state)
  end

  def handle_info(message, state) do
    dispatch(state.sidecar_mod.handle_message(state.sidecar, message), state)
  end

  @impl GenServer
  def terminate(_reason, %{sidecar: nil}), do: :ok
  def terminate(_reason, state), do: state.sidecar_mod.stop(state.sidecar)

  defp dispatch({:sidecar_control, msg}, state), do: control(msg, touch(state))

  defp dispatch({:sidecar_audio, pcm}, state) do
    notify(state, {:meeting_audio, pcm})
    {:noreply, touch(state)}
  end

  defp dispatch({:sidecar_exit, status}, state), do: exited(status, state)
  defp dispatch(:ignore, state), do: {:noreply, state}

  defp control(%{"type" => "state", "phase" => phase}, state)
       when phase in ~w(joining knocking) do
    notify(state, {:meeting_phase, phase_atom(phase), %{}})
    {:noreply, state}
  end

  # "leaving" has no normalized counterpart: the Session learns the bot is out
  # from `meeting_ended`, which always follows.
  defp control(%{"type" => "state", "phase" => "leaving"}, state), do: {:noreply, state}

  defp control(%{"type" => "join_result", "status" => status} = msg, state)
       when status in ~w(admitted denied login_required signin_required bot_blocked knock_timeout) do
    notify(state, {:meeting_join_result, join_status(status), meta(msg)})
    {:noreply, %{state | admitted?: status == "admitted"}}
  end

  defp control(%{"type" => "roster", "participants" => participants}, state)
       when is_list(participants) do
    case normalize_roster(participants) do
      {:ok, roster} ->
        notify(state, {:meeting_roster, roster})
        {:noreply, state}

      :error ->
        fail(state, {:protocol_error, :malformed_roster})
    end
  end

  defp control(%{"type" => "active_speaker", "id" => id, "t_ms" => t_ms}, state)
       when is_binary(id) and is_integer(t_ms) and t_ms >= 0 do
    notify(state, {:meeting_active_speaker, id, t_ms})
    {:noreply, state}
  end

  defp control(%{"type" => "chat_posted"}, state) do
    notify(state, {:meeting_chat_posted})
    {:noreply, state}
  end

  defp control(%{"type" => "meeting_ended", "reason" => reason}, state)
       when reason in ~w(host_removed meeting_closed left) do
    notify(state, {:meeting_ended, end_reason(reason)})
    {:noreply, state}
  end

  defp control(%{"type" => "error", "code" => code, "message" => message}, state),
    do: fail(state, {:sidecar_error, code, message})

  defp control(%{"type" => "log", "level" => level, "message" => message}, state)
       when is_binary(message) do
    Logger.log(log_level(level), "meetbot: " <> message)
    {:noreply, state}
  end

  defp control(%{"type" => "pong"}, state), do: {:noreply, state}

  defp control(%{"type" => type}, state),
    do: fail(state, {:protocol_error, {:unexpected_control, type}})

  defp exited(_status, %{admitted?: false, relaunches: relaunches} = state)
       when relaunches < @relaunch_max,
       do: relaunch(state)

  defp exited(status, state), do: fail(state, {:sidecar_crashed, status})

  defp relaunch(state) do
    state.sidecar_mod.stop(state.sidecar)

    case state.sidecar_mod.launch(self(), state.launch_opts) do
      {:ok, sidecar} ->
        join(%{state | sidecar: sidecar, relaunches: state.relaunches + 1})

      {:error, reason} ->
        fail(%{state | sidecar: nil}, {:sidecar_crashed, reason})
    end
  end

  defp join(state) do
    case state.sidecar_mod.send_control(state.sidecar, state.join_msg) do
      :ok ->
        notify(state, {:meeting_phase, :joining, %{}})
        {:noreply, %{state | ping_pending?: false, ping_sent_mono: nil, last_sent_mono: mono()}}

      {:error, :closed} ->
        fail(state, {:sidecar_crashed, :closed})
    end
  end

  defp ping_policy(%{ping_pending?: true} = state) do
    if mono() - state.ping_sent_mono >= state.timers.pong_grace_ms do
      fail(state, :sidecar_wedged)
    else
      {:noreply, state}
    end
  end

  defp ping_policy(%{sidecar: nil} = state), do: {:noreply, state}

  # The keepalive keys on the last frame we SENT, not the last we received. The
  # sidecar runs its own liveness watchdog and leaves the meeting after its
  # inbound goes silent past a bound; during capture the daemon receives a steady
  # audio stream while sending nothing, so an inbound-keyed idle timer never
  # fires — and every capture died at the sidecar's 45 s watchdog.
  defp ping_policy(state) do
    if mono() - state.last_sent_mono >= state.timers.ping_idle_ms do
      ping(state)
    else
      {:noreply, state}
    end
  end

  defp ping(state) do
    now = mono()

    case state.sidecar_mod.send_control(state.sidecar, %{"type" => "ping"}) do
      :ok -> {:noreply, %{state | ping_pending?: true, ping_sent_mono: now, last_sent_mono: now}}
      {:error, :closed} -> fail(state, {:sidecar_crashed, :closed})
    end
  end

  defp fail(state, reason) do
    notify(state, {:meeting_source_error, reason})
    {:stop, :normal, state}
  end

  # A handshake timeout is the one launch failure with its own named bound, so
  # it is reported through the shared expiry emitter rather than as raw detail.
  defp launch_error({:handshake_timeout, ms}, session_id) do
    {:error, expired} = Timeouts.expired(:meetbot_handshake, ms, %{session_id: session_id})
    expired
  end

  defp launch_error(reason, _session_id), do: reason

  defp normalize_roster(participants) do
    participants
    |> Enum.take(@roster_max)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case entry do
        %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) ->
          {:cont, {:ok, [%{id: id, name: name} | acc]}}

        _other ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp resolve_binary(args) do
    case Map.get(args, :binary_path) do
      path when is_binary(path) -> {:ok, path}
      nil -> SidecarInstaller.binary_path()
    end
  end

  defp launch_opts(args, binary_path, profile_dir) do
    Keyword.merge(
      [
        binary_path: binary_path,
        profile_dir: profile_dir,
        handshake_timeout_ms: Map.get(args, :handshake_timeout_ms, Timeouts.meetbot_handshake())
      ],
      Map.get(args, :sidecar_opts, [])
    )
  end

  # Built once: the sidecar is re-sent this exact message after a relaunch, so
  # the meeting it rejoins is the meeting it was asked to join.
  defp join_msg(args, profile_dir) do
    config = Map.fetch!(args, :config)

    %{
      "type" => "join",
      "platform" => "meet",
      "url" => Map.fetch!(args, :url),
      "passcode" => nil,
      "bot_name" => config.bot_name,
      "announce" => config.announce,
      "announce_message" => config.announce_message,
      "profile_dir" => profile_dir
    }
  end

  defp timers(args) do
    defaults = %{
      tick_ms: @tick_ms,
      ping_idle_ms: @ping_idle_ms,
      pong_grace_ms: @pong_grace_ms
    }

    Map.merge(defaults, Map.get(args, :timers, %{}))
  end

  defp meta(msg), do: Map.take(msg, ["detail", "message"])

  defp phase_atom("joining"), do: :joining
  defp phase_atom("knocking"), do: :knocking

  defp join_status("admitted"), do: :admitted
  defp join_status("denied"), do: :denied
  defp join_status("login_required"), do: :login_required
  defp join_status("signin_required"), do: :signin_required
  defp join_status("bot_blocked"), do: :bot_blocked
  defp join_status("knock_timeout"), do: :knock_timeout

  defp end_reason("host_removed"), do: :host_removed
  defp end_reason("meeting_closed"), do: :meeting_closed
  defp end_reason("left"), do: :left

  defp log_level("debug"), do: :debug
  defp log_level("warn"), do: :warning
  defp log_level("error"), do: :error
  defp log_level(_other), do: :info

  defp notify(state, message), do: send(state.session, message)

  defp touch(state), do: %{state | ping_pending?: false, ping_sent_mono: nil}

  defp mono, do: System.monotonic_time(:millisecond)
end
