defmodule FermixCore.Browser.HostLauncher do
  @moduledoc """
  Whether a new `fermix` task may run in the Fermix app's browser pane,
  opening the app first when it is not connected and launching is allowed
  (`[fermix_core.browser] launch_app`).

  The decision is a pure step (`step/4`) and the loop around it takes its
  effects as functions, so the table is tested with an injected launcher and
  clock and no test launches anything. One deadline bounds the whole decision
  (`host_launch_timeout_ms`), the app is opened at most once per decision, and
  the poll count is capped as well, so a clock that stops cannot hold it open.

  | the host | `launch_app` | step | decided |
  |---|---|---|---|
  | attached, reported available | either | none | the pane |
  | attached, reported unavailable | either | none | Chrome, with the host's reason |
  | attached, no report yet | either | wait | by the first report; Chrome at the deadline |
  | nothing listening for a host | either | none | Chrome: nothing could attach |
  | listening, not attached | false | none | Chrome |
  | listening, not attached | true | open the app once, wait | by the attach and first report; Chrome if the launch fails or at the deadline |

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

  @type decision :: :fermix_app | {:managed, String.t()}
  @type step :: decision() | :launch | :wait

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
      launcher: Keyword.get(opts, :launcher, &launch/1),
      now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      launch_app: config.launch_app,
      poll_ms: config.wait_poll_interval_ms
    }

    deadline = deps.now.() + config.host_launch_timeout_ms
    polls = div(config.host_launch_timeout_ms, config.wait_poll_interval_ms) + 1
    run(deps, deadline, false, polls)
  end

  @doc "One step of the decision, from what the host last said and how long is left."
  @spec step(HostAvailability.t(), boolean(), boolean(), integer()) :: step()
  def step(%HostAvailability{} = host, launched?, launch_app?, remaining_ms)
      when is_boolean(launched?) and is_boolean(launch_app?) and is_integer(remaining_ms) do
    cond do
      HostAvailability.usable?(host) -> :fermix_app
      host.attached -> attached_step(host, remaining_ms)
      not host.listening -> {:managed, HostAvailability.unavailable_reason(host)}
      not launch_app? -> {:managed, HostAvailability.unavailable_reason(host)}
      not launched? -> :launch
      true -> launched_step(remaining_ms)
    end
  end

  defp attached_step(host, remaining_ms) do
    cond do
      HostAvailability.reported?(host) -> {:managed, HostAvailability.unavailable_reason(host)}
      remaining_ms > 0 -> :wait
      true -> {:managed, "the app connected but did not report its browser in time"}
    end
  end

  defp launched_step(remaining_ms) when remaining_ms > 0, do: :wait

  defp launched_step(_remaining_ms),
    do: {:managed, "the app was opened but did not connect in time"}

  # A spent poll count reads as a spent deadline, so the loop ends on the same
  # decision whichever bound ran out first.
  defp run(deps, deadline, launched?, polls) do
    remaining = if polls > 0, do: deadline - deps.now.(), else: 0

    case step(deps.host.(), launched?, deps.launch_app, remaining) do
      :launch -> launched(deps.launcher.(max(remaining, 1)), deps, deadline, polls)
      :wait -> wait(deps, deadline, launched?, polls, remaining)
      decision -> decision
    end
  end

  defp launched(:ok, deps, deadline, polls), do: run(deps, deadline, true, polls)

  defp launched({:error, reason}, _deps, _deadline, _polls) when is_binary(reason),
    do: {:managed, "the app could not be opened: #{reason}"}

  defp wait(deps, deadline, launched?, polls, remaining) do
    deps.sleep.(min(deps.poll_ms, remaining))
    run(deps, deadline, launched?, polls - 1)
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
