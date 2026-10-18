defmodule FermixCore.Native.Notifications.DBus do
  @moduledoc """
  Desktop notifications on Linux (M76 §4.5): `org.freedesktop.Notifications`
  on the session bus, asked over `busctl --user` the way
  `Setup.SecretService.Probe` asks after the keyring.

  The engine runs on the host as the account's systemd user unit, outside the
  Flatpak sandbox, so it reaches the session bus itself; `busctl` is systemd's,
  and the package already requires systemd. No `libnotify`, no `notify-send`.

  Two questions, each one bounded `busctl` call:

    1. Does anything own `org.freedesktop.Notifications`? Asked of the bus
       itself (`NameHasOwner`), so an activatable server is not started by the
       asking. This is `ready/2`. A headless host, a `--system` unit (no
       session bus for the account) and a logged-out laptop all answer no.
    2. `Notify`, which `post/2` sends only once the first answers yes, so the
       post at fire time asks what the readiness the reminder was stored on
       asked, and a post never starts a server either.

  The notification names Fermix and always carries the `desktop-entry` hint
  `io.tezra.Fermix`: a server shows the Linux app's name and icon when that
  entry is installed and ignores the hint when it is not, so whether the app
  is installed needs no look. It asks for the `alarm-clock-elapsed` sound (or
  for none), normal urgency and the server's own timeout. It offers no
  actions: an `ActionInvoked` signal needs a listener on the bus for the
  notification's life, which a one-shot `busctl call` cannot be.
  """

  @behaviour FermixCore.Native.Notifications

  alias FermixCore.CommandRunner
  alias FermixCore.Native.Notifications
  alias FermixCore.SessionBus

  @bus "org.freedesktop.DBus"
  @bus_path "/org/freedesktop/DBus"
  @service "org.freedesktop.Notifications"
  @service_path "/org/freedesktop/Notifications"
  # The one bound on a call: busctl's own method timeout is never set, so it
  # cannot answer first with a failure where this bound would say timeout.
  @call_timeout_ms 1_500
  @evidence_bytes 200

  @app_name "Fermix"
  @desktop_entry "io.tezra.Fermix"
  @sound_name "alarm-clock-elapsed"
  # Notify(app_name, replaces_id, app_icon, summary, body, actions, hints, expire_timeout)
  @notify_signature "susssasa{sv}i"
  @urgency_normal "1"
  @server_default_timeout "-1"

  @no_server "no desktop notification server is running on this machine"

  @typep runner :: (String.t(), [String.t()] -> {:ok, String.t()} | {:error, term()})

  @doc """
  Whether a desktop notification server owns its name on the session bus now.
  `context` is not read: Linux holds no grant a turn could prompt for.
  `opts[:runner]` and `opts[:find_executable]` are test seams;
  `opts[:supervised]` reaches `CommandRunner` unchanged.
  """
  @impl true
  @spec ready(map(), keyword()) :: :ok | {:error, String.t()}
  def ready(context, opts) when is_map(context) and is_list(opts) do
    with {:ok, busctl} <- busctl(opts),
         :ok <- name_has_owner(busctl, runner(opts)) do
      :ok
    else
      {:error, reason} -> {:error, sentence(reason)}
    end
  end

  @doc """
  Shows one notification: the owner question, then one `Notify`. Answers the
  server's id for it, in decimal. The seams are `ready/2`'s.
  """
  @impl true
  @spec post(Notifications.notification(), keyword()) ::
          {:ok, Notifications.id()} | {:error, Notifications.reason()}
  def post(%{title: title, body: body, sound: sound} = notification, opts)
      when is_binary(title) and title != "" and is_binary(body) and is_boolean(sound) and
             is_list(opts) do
    runner = runner(opts)

    with {:ok, busctl} <- busctl(opts),
         :ok <- name_has_owner(busctl, runner) do
      notify(busctl, runner, notification)
    end
  end

  defp busctl(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case find.("busctl") do
      nil -> {:error, :backend_missing}
      busctl -> {:ok, busctl}
    end
  end

  defp name_has_owner(busctl, runner) do
    case runner.(busctl, call_args([@bus, @bus_path, @bus, "NameHasOwner", "s", @service])) do
      {:ok, output} -> owner(output)
      {:error, reason} -> {:error, call_failure("NameHasOwner", reason)}
    end
  end

  # busctl prints a typed value: `b true`.
  defp owner(output) do
    case String.trim(output) do
      "b true" -> :ok
      "b false" -> {:error, :no_server}
      other -> {:error, {:failed, evidence("NameHasOwner", {:unexpected_output, other})}}
    end
  end

  defp notify(busctl, runner, notification) do
    case runner.(busctl, call_args(notify_args(notification))) do
      {:ok, output} -> notification_id(output)
      {:error, reason} -> {:error, call_failure("Notify", reason)}
    end
  end

  defp notify_args(%{title: title, body: body, sound: sound}) do
    [@service, @service_path, @service, "Notify", @notify_signature] ++
      [@app_name, "0", "", title, body] ++
      ["0"] ++
      hints(sound) ++
      [@server_default_timeout]
  end

  # `a{sv}` as busctl spells it: the count, then each key, its variant's type
  # and its value.
  defp hints(sound) do
    ["3", "desktop-entry", "s", @desktop_entry, "urgency", "y", @urgency_normal] ++
      sound_hint(sound)
  end

  defp sound_hint(true), do: ["sound-name", "s", @sound_name]
  defp sound_hint(false), do: ["suppress-sound", "b", "true"]

  # `u 42`: the server's id for the notification, which is never 0.
  defp notification_id(output) do
    case Regex.run(~r/^u ([1-9][0-9]*)$/, String.trim(output)) do
      [_, id] -> {:ok, id}
      nil -> {:error, {:failed, evidence("Notify", {:unexpected_output, output})}}
    end
  end

  # Everything after `--` is an argument, never an option: the expiry is a
  # negative integer, and the summary and body are the owner's own text.
  defp call_args(rest), do: ["--user", "--", "call" | rest]

  # A bus that cannot be reached has no server to post to; a call that ran
  # out its bound is a timeout; anything else fails with its evidence.
  defp call_failure(member, {:helper_failed, _code, output} = reason) do
    if SessionBus.unreachable?(output),
      do: :no_server,
      else: {:failed, evidence(member, reason)}
  end

  defp call_failure(_member, :timeout), do: :timeout
  defp call_failure(member, reason), do: {:failed, evidence(member, reason)}

  defp sentence(:no_server), do: @no_server

  defp sentence(:backend_missing) do
    "busctl is not installed, so Fermix cannot ask this machine's session bus for a " <>
      "desktop notification server"
  end

  defp sentence(:timeout) do
    "the session bus did not answer in time, so no desktop notification server could be " <>
      "asked for"
  end

  defp sentence({:failed, evidence}) do
    "the session bus could not be asked for a desktop notification server (#{evidence})"
  end

  defp evidence(member, {:helper_failed, code, output}),
    do: "#{member}: exit #{code}: #{clip(output)}"

  defp evidence(member, {:unexpected_output, output}),
    do: "#{member}: unexpected output: #{clip(output)}"

  defp evidence(member, other), do: "#{member}: #{clip(inspect(other))}"

  defp clip(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.split("\n")
    |> List.first("")
    |> String.slice(0, @evidence_bytes)
  end

  # One bounded subprocess per call. The runner shape is what the test seam
  # provides; in production it is `CommandRunner.run/3` with the caller's
  # `supervised:` posture.
  @spec runner(keyword()) :: runner()
  defp runner(opts) do
    case Keyword.get(opts, :runner) do
      nil -> &run_bounded(&1, &2, Keyword.take(opts, [:supervised]))
      runner when is_function(runner, 2) -> runner
    end
  end

  defp run_bounded(busctl, args, supervised) do
    case CommandRunner.run(busctl, args, [timeout_ms: @call_timeout_ms] ++ supervised) do
      {:ok, %{exit: 0, stdout: output}} -> {:ok, output}
      {:ok, %{exit: code, stdout: output}} -> {:error, {:helper_failed, code, output}}
      {:error, {:timeout, _ms}} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end
end
