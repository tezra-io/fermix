defmodule FermixCore.Browser.HostLauncher do
  @moduledoc """
  Whether a new `fermix` task may run in the Fermix app's browser pane,
  opening the app first when it is not connected and launching is allowed
  (`[fermix_core.browser] launch_app`).

  The decision is a pure step (`step/2`) and the loop around it takes its
  effects as functions, so the table is tested with an injected launcher and
  clock and no test launches anything. One deadline bounds each launch
  (`host_launch_timeout_ms`), recorded where every decision reads it
  (`HostAvailability.launching/2`), so the app is opened once however many
  tasks start while it comes up: a task that finds a launch pending waits on
  that launch's deadline, and only the deadline ends the wait, since an app
  that died before it attached is indistinguishable from a slow one. The poll
  count is capped as well, so a clock that stops cannot hold a decision open.

  | the host | `launch_app` | step | decided |
  |---|---|---|---|
  | attached, reported available | either | none | the pane |
  | attached, reported unavailable or stopping | either | none | Chrome, with the host's reason |
  | attached, no report yet | either | wait | by the first report; Chrome at the deadline |
  | nothing listening for a host | either | none | Chrome: nothing could attach |
  | listening, not attached | false | none | Chrome |
  | listening, not attached, the last host quit | true | none | Chrome, until the app attaches by itself |
  | listening, not attached, a launch pending | true | wait | by the attach and first report; Chrome at that launch's deadline |
  | listening, not attached, the last launch never attached | true | none | Chrome, for `host_launch_cooldown_ms` after its deadline |
  | listening, not attached | true | open the app once, wait | by the attach and first report; Chrome if the launch fails or at the deadline |

  The last two rows are the bounded answer to a quit the engine never hears
  of: an app quit before it attached sends no `host_stopping`, so the engine
  learns only that its launch did not attach, and does not open it again for a
  while rather than on every task.

  `launch/1` is the one real launcher: `open -g -j -b <bundle id> --args
  --background`. The engine release carries no bundle identifier, because one
  engine tree ships inside both the app and its development identity, which
  is applied when the app is staged. So the identifier is read from the bundle
  this engine runs inside (`EngineOwner.app_bundle_path/0`): its `Info.plist`,
  which the app's staging proves agrees with the product configuration it
  staged. The development app therefore opens the development app.
  """

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.CommandRunner
  alias FermixCore.Setup.EngineOwner

  @open "/usr/bin/open"
  @plutil "/usr/bin/plutil"
  @not_connected "the app was opened but did not connect in time"

  @type decision :: :fermix_app | {:managed, String.t()}
  @type step :: decision() | :launch | :wait

  @typedoc """
  What a step knows besides the host: whether launching is allowed, how long
  the decision has left, the monotonic millisecond now, and the cooldown after
  a launch that did not attach.
  """
  @type clock :: %{
          launch_app?: boolean(),
          remaining_ms: integer(),
          now_ms: integer(),
          cooldown_ms: pos_integer()
        }

  @doc """
  Decide, launching and waiting as the table says.

  `opts` may carry `:host_availability` (the availability process to read),
  `:launcher` (`(timeout_ms -> :ok | {:error, String.t()})`), `:now` (a
  millisecond clock) and `:sleep`; each defaults to the real one.
  """
  @spec decide(Config.t(), keyword()) :: decision()
  def decide(%Config{} = config, opts \\ []) when is_list(opts) do
    host = Keyword.get(opts, :host_availability, HostAvailability)

    deps = %{
      host: fn -> HostAvailability.current(host) end,
      launching: fn until_ms -> HostAvailability.launching(host, until_ms) end,
      launcher: Keyword.get(opts, :launcher, &launch/1),
      now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      launch_app: config.launch_app,
      poll_ms: config.wait_poll_interval_ms,
      cooldown_ms: config.host_launch_cooldown_ms
    }

    deadline = deps.now.() + config.host_launch_timeout_ms
    polls = div(config.host_launch_timeout_ms, config.wait_poll_interval_ms) + 1
    run(deps, deadline, polls)
  end

  @doc "One step of the decision, from what the host last said and the clock."
  @spec step(HostAvailability.t(), clock()) :: step()
  def step(%HostAvailability{} = host, %{launch_app?: launch_app?} = clock)
      when is_boolean(launch_app?) do
    cond do
      HostAvailability.usable?(host) -> :fermix_app
      host.attached -> attached_step(host, clock.remaining_ms)
      not host.listening -> {:managed, HostAvailability.unavailable_reason(host)}
      not launch_app? -> {:managed, HostAvailability.unavailable_reason(host)}
      true -> launch_step(host, clock)
    end
  end

  defp attached_step(host, remaining_ms) do
    cond do
      HostAvailability.reported?(host) or host.stopping ->
        {:managed, HostAvailability.unavailable_reason(host)}

      remaining_ms > 0 ->
        :wait

      true ->
        {:managed, "the app connected but did not report its browser in time"}
    end
  end

  defp launch_step(host, clock) do
    cond do
      host.quit -> {:managed, "the app was quit, and is not opened again until it is started"}
      pending?(host, clock.now_ms) -> launched_step(clock.remaining_ms)
      cooling?(host, clock) -> {:managed, @not_connected}
      true -> :launch
    end
  end

  defp pending?(%{launch_until: until}, now_ms), do: is_integer(until) and now_ms < until

  defp cooling?(%{launch_until: until}, clock),
    do: is_integer(until) and clock.now_ms < until + clock.cooldown_ms

  defp launched_step(remaining_ms) when remaining_ms > 0, do: :wait
  defp launched_step(_remaining_ms), do: {:managed, @not_connected}

  # A spent poll count reads as a spent deadline, so the loop ends on the same
  # decision whichever bound ran out first. A task that finds a launch pending
  # waits on that launch's deadline, never past its own.
  defp run(deps, deadline, polls) do
    host = deps.host.()
    now = deps.now.()
    deadline = waited_deadline(host, deadline, now)
    remaining = if polls > 0, do: deadline - now, else: 0
    clock = %{launch_app?: deps.launch_app, remaining_ms: remaining, now_ms: now}

    case step(host, Map.put(clock, :cooldown_ms, deps.cooldown_ms)) do
      :launch -> launch(deps, deadline, polls, now)
      :wait -> wait(deps, deadline, polls, remaining)
      decision -> decision
    end
  end

  defp waited_deadline(%{launch_until: until}, deadline, now)
       when is_integer(until) and until > now,
       do: min(deadline, until)

  defp waited_deadline(_host, deadline, _now), do: deadline

  # The deadline is recorded before the app is opened, so a task that starts
  # while it comes up finds the launch pending. A launch that fails at once
  # ends there, and its cooldown starts from that moment.
  defp launch(deps, deadline, polls, now) do
    :ok = deps.launching.(deadline)

    case deps.launcher.(max(deadline - now, 1)) do
      :ok ->
        run(deps, deadline, polls)

      {:error, reason} when is_binary(reason) ->
        :ok = deps.launching.(deps.now.())
        {:managed, "the app could not be opened: #{reason}"}
    end
  end

  defp wait(deps, deadline, polls, remaining) do
    deps.sleep.(min(deps.poll_ms, remaining))
    run(deps, deadline, polls - 1)
  end

  @doc """
  Open the app this engine runs inside, in the background and without taking
  focus. Its browser host attaches on its own; `decide/2` waits for that.
  """
  @spec launch(pos_integer()) :: :ok | {:error, String.t()}
  def launch(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, bundle} <- running_bundle(),
         {:ok, bundle_id} <- bundle_identifier(bundle, timeout_ms) do
      open_app(bundle_id, timeout_ms)
    end
  end

  defp running_bundle do
    case EngineOwner.app_bundle_path() do
      bundle when is_binary(bundle) -> {:ok, bundle}
      nil -> {:error, "this engine is not running inside the app"}
    end
  end

  defp bundle_identifier(bundle, timeout_ms) do
    plist = Path.join([bundle, "Contents", "Info.plist"])
    args = ["-extract", "CFBundleIdentifier", "raw", "-o", "-", plist]

    case CommandRunner.run(@plutil, args, timeout_ms: timeout_ms) do
      {:ok, %{exit: 0, stdout: out}} -> identifier(String.trim(out), plist)
      {:ok, %{exit: code, stdout: out}} -> {:error, "plutil exited #{code}: #{String.trim(out)}"}
      {:error, reason} -> {:error, "plutil could not run: #{inspect(reason)}"}
    end
  end

  defp identifier("", plist), do: {:error, "#{plist} names no bundle identifier"}
  defp identifier(bundle_id, _plist), do: {:ok, bundle_id}

  defp open_app(bundle_id, timeout_ms) do
    args = ["-g", "-j", "-b", bundle_id, "--args", "--background"]

    case CommandRunner.run(@open, args, timeout_ms: timeout_ms) do
      {:ok, %{exit: 0}} -> :ok
      {:ok, %{exit: code, stdout: out}} -> {:error, "open exited #{code}: #{String.trim(out)}"}
      {:error, reason} -> {:error, "open could not run: #{inspect(reason)}"}
    end
  end
end
