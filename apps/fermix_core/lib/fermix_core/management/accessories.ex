defmodule FermixCore.Management.Accessories do
  @moduledoc """
  The `accessories.*` methods (M91 E3; `priv/management/PROTOCOL.md`,
  *Accessories*): the status a Mac's Pet setup and Manage screens draw, with a
  long poll on its `key`, and the owner's actions on a paired accessory, its
  pairing and its call.

  A stateless adapter, as `Management.Mobile` is. The ports, the links and
  the calls have one owner, the accessories subtree in the channels app, which
  this app does not compile against, so every call into it goes by function
  name to the provider that app registers at `:accessories_management_provider`
  (`FermixChannels.Accessories.Management`). This module adds what core holds
  itself (the switch, the engine's role and platform, the pairing store's
  records and the chosen voice device, the home's call lease, the configured
  voice), turns the provider's atom-keyed facts into the string-keyed wire,
  and owns every sentence and every action a row offers.

  Accessories run only on a local Mac primary (M91 D13): elsewhere the status
  answers `needs_local_primary` and every other method is refused with its
  sentence. Every success answers the whole status, so the app redraws from
  the daemon's own picture after each action.
  """

  alias FermixCore.Accessories.Attach
  alias FermixCore.Accessories.Config
  alias FermixCore.Accessories.Control
  alias FermixCore.Accessories.Readiness
  alias FermixCore.Accessories.Record
  alias FermixCore.Accessories.Store
  alias FermixCore.Accessories.VoiceDevice
  alias FermixCore.Auth.Redaction
  alias FermixCore.Home.Role
  alias FermixCore.Management.Settings.Voice
  alias FermixCore.Realtime.CallLease
  alias FermixCore.Realtime.Config, as: RealtimeConfig
  alias FermixCore.Setup.ConfigStore

  require Logger

  @capability "accessories"
  @max_wait_ms 25_000
  # Each word from the watcher is one read again; a wait answers at the first
  # that moved the key, and reads at most this many.
  @max_rereads 64
  # What the watcher does not own (the home's call lease, voice readiness, the
  # switch, the pairing store's files) is read again this often while a wait
  # holds: at most 13 reads of a 25 s wait.
  @reread_ms 2_000
  @max_name_bytes 64
  @max_path_bytes 256
  @max_call_id_bytes 64
  @max_task_bytes 64
  @max_rounds 3
  @checks %{"tone" => :tone, "mic" => :mic, "face" => :face, "motion" => :motion}
  @default_mic_seconds 5
  @calibrate_ops %{
    "begin" => :begin,
    "nudge" => :nudge,
    "set_zero" => :set_zero,
    "cancel" => :cancel
  }
  @axes %{"pan" => :pan, "tilt" => :tilt}
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @hex32 ~r/\A[0-9a-f]{32}\z/
  @key_pattern ~r/\A[0-9a-f]{16}\z/
  @token ~r/\A[a-z][a-z0-9_]{0,47}\z/
  @host_caps ~w(mic speaker screen touch pet motion battery)a

  # -- sentences -------------------------------------------------------------------

  @off_sentence "StackChan is off."
  @needs_primary_sentence "StackChan setup needs a local Mac primary."
  @not_running_sentence "StackChan is on but has not started. Restart Fermix to start it."
  @connect_sentence "Connect a StackChan."
  @on_sentence "StackChan is on."
  @records_sentence "The list of paired robots could not be read. See the daemon log."
  @no_ports_sentence "Plug your StackChan into this Mac with its USB-C cable."
  @owner_only_sentence "Only the owner can set up or control StackChan: use the Fermix app " <>
                         "or your own terminal."

  @voice_sentences %{
    nil => "Voice is ready.",
    "voice_disabled" => "Voice is off. Turn on Talk to Fermix in Voice settings.",
    "missing_key" => "Voice needs its provider key. Add it in Voice settings.",
    "restart_required" =>
      "Voice settings changed since Fermix started. Restart Fermix to apply them."
  }

  @device_locked_sentence "The voice device can change once the call has finished."
  @device_unsaved_sentence "The voice device could not be saved. See the daemon log."

  @port_sentences %{
    unrelated: "A USB serial device is plugged in.",
    attaching: "Checking the USB device.",
    unpaired: "StackChan found. Fermix firmware is compatible.",
    attached: "Connected by USB.",
    busy: "Another app is using StackChan's USB port. Close it and try again.",
    needs_firmware:
      "This USB device isn't running Fermix firmware. If it's your StackChan, install the " <>
        "firmware first.",
    not_paired: "This robot isn't paired with this Mac.",
    released: "Install the firmware update now, then choose Reconnect.",
    vanished: "The USB device was unplugged.",
    failed: "The USB connection failed. Try again."
  }
  @update_sentences %{
    firmware: "Update the robot firmware.",
    fermix: "Update Fermix: this robot's firmware is newer than this Fermix."
  }

  @connection_sentences %{
    attached: "Connected by USB. Firmware compatible.",
    attaching: "Connecting to StackChan.",
    unplugged: "Plug StackChan into this Mac.",
    failed: "StackChan's USB connection failed. Try again."
  }
  @calibration_sentences %{
    "missing" => "Head movement is off until the robot is calibrated.",
    "valid" => "The head is calibrated.",
    "calibrating" => "Calibrating the head: nudge each axis to its center, then set zero.",
    "failed" =>
      "The head calibration did not finish, so head movement stays off until a calibration " <>
        "succeeds."
  }
  @phase_sentences %{starting: "The call is starting.", ending: "The call is ending."}

  @power_sentence "StackChan needs more power. Plug it into one of this Mac's USB-C ports, " <>
                    "not a hub."

  @pairing_sentences %{
    begun: "Tap Pair with this Mac on your robot.",
    offered: "Check the code on your robot. It should match the code shown here.",
    revealed: "Check the code on your robot. It should match the code shown here.",
    committing: "Pairing your robot. Keep it plugged in.",
    done: "Your robot is paired."
  }
  @closed_sentences %{
    owner: "Pairing was cancelled.",
    expired: "Pairing took longer than two minutes. Start again.",
    mismatch_limit: "The codes did not match three times. Start pairing again.",
    invalid_offer: "The robot's pairing answer did not check out, so nothing was paired.",
    invalid_reveal: "The robot's pairing answer did not check out, so nothing was paired.",
    link_reset: "The robot's connection reset during pairing. Start again."
  }

  @call_ended_sentence "The call ended."
  @call_sentences %{
    "unplugged" => "StackChan was unplugged, so the call ended.",
    "link_lost" => "StackChan's connection was lost, so the call ended.",
    "forgotten" => "The robot was forgotten, so its call ended.",
    "call_in_progress" => "Another voice call is in progress.",
    "not_selected" =>
      "StackChan is not your voice device. Choose it in Pet to call from the robot.",
    "not_attached" => "That robot is not connected.",
    "call_failed" => "The call could not start. See the daemon log."
  }

  @no_port_sentence "No USB device is plugged in at that port."
  @released_sentence "That port is released for a firmware update. Choose Reconnect first."
  @no_pairing_sentence "Pairing has not been started on that port."
  @unknown_sentence "No paired robot has that id."
  @not_attached_sentence "That robot is not connected."
  @task_sentence "That task cannot be cancelled."
  @set_nothing_sentence "Send at least one of volume, brightness or motion."
  @busy_call_sentence "End the call first."
  @incapable_sentence "StackChan cannot do that."
  @pairing_open_sentence "Pairing is already open on this port."
  @already_paired_sentence "StackChan is already paired."
  @not_answered_sentence "The robot has not answered yet. Try again in a moment."
  @stale_attempt_sentence "That pairing attempt has ended, so look at it again."
  @stale_call_sentence "That call has ended, so look at it again."
  @failed_sentence "StackChan could not do that. See the daemon log."
  @switch_not_started_sentence "StackChan is on but could not start. See the daemon log."
  @switch_not_ready_sentence "StackChan starts the next time Fermix starts."
  @switch_failed_sentence "StackChan's switch could not be applied. See the daemon log."

  @type refusal ::
          {:unavailable, String.t(), String.t()}
          | {:invalid_params, String.t(), String.t()}
          | {:changed, String.t()}
  @type route_result :: {:ok, map()} | {:error, atom(), map()}

  # -- what other modules read -------------------------------------------------------

  @doc "The capability every refusal of this family names."
  @spec capability() :: String.t()
  def capability, do: @capability

  @doc "The longest a status wait holds, in milliseconds."
  @spec max_wait_ms() :: pos_integer()
  def max_wait_ms, do: @max_wait_ms

  @doc "The sentence the daemon socket's refusal of an owner's decision carries."
  @spec owner_only_sentence() :: String.t()
  def owner_only_sentence, do: @owner_only_sentence

  @doc "Every operator-facing sentence this module can put on the wire."
  @spec sentences() :: [String.t()]
  def sentences do
    [
      @off_sentence,
      @needs_primary_sentence,
      @not_running_sentence,
      @connect_sentence,
      @on_sentence,
      @records_sentence,
      @no_ports_sentence,
      @owner_only_sentence,
      @device_locked_sentence,
      @device_unsaved_sentence,
      @power_sentence,
      @call_ended_sentence,
      @no_port_sentence,
      @released_sentence,
      @no_pairing_sentence,
      @unknown_sentence,
      @not_attached_sentence,
      @task_sentence,
      @busy_call_sentence,
      @incapable_sentence,
      @pairing_open_sentence,
      @already_paired_sentence,
      @not_answered_sentence,
      @stale_attempt_sentence,
      @stale_call_sentence,
      @failed_sentence,
      @switch_not_started_sentence,
      @switch_not_ready_sentence,
      @switch_failed_sentence,
      fault_sentence("storage_fault"),
      @set_nothing_sentence
    ] ++
      VoiceDevice.sentences() ++
      Map.values(@voice_sentences) ++
      Map.values(@port_sentences) ++
      Map.values(@update_sentences) ++
      Map.values(@connection_sentences) ++
      Map.values(@calibration_sentences) ++
      Map.values(@phase_sentences) ++
      Map.values(@pairing_sentences) ++
      Map.values(@closed_sentences) ++ Map.values(@call_sentences)
  end

  # -- the methods -----------------------------------------------------------------

  @doc """
  Routes one `accessories.*` request whose method the protocol published:
  validates its params, refuses it where accessories do not run, calls the
  provider and answers the status after it.
  """
  @spec route(String.t(), map(), keyword()) :: route_result()
  def route("accessories.status", params, opts), do: status_request(params, opts)

  def route("accessories." <> _rest = method, params, opts) when is_map(params) do
    with {:ok, action} <- action(method, params),
         :ok <- admitted(action, opts) do
      act(action, opts)
    end
  end

  @doc "`accessories.status`: the picture as it stands."
  @spec status(keyword()) :: {:ok, map()}
  def status(opts \\ []) when is_list(opts), do: {:ok, view(facts(opts))}

  @doc """
  `accessories.status {after, wait_ms}`: the picture once its key is not
  `after_key`, or when `wait_ms` passed. Woken by the watcher's every change,
  and by the watcher ending (the switch turned off).
  """
  @spec status_after(String.t(), non_neg_integer(), keyword()) :: {:ok, map()}
  def status_after(after_key, wait_ms, opts \\ [])
      when is_binary(after_key) and is_integer(wait_ms) and wait_ms in 0..@max_wait_ms//1 do
    {:ok, record} = status(opts)

    if record["key"] == after_key and wait_ms > 0,
      do: hold(after_key, wait_ms, opts),
      else: {:ok, record}
  end

  @doc """
  Starts or stops the accessory link while the daemon runs, once settings
  have written its switch. `:ok` when it followed; otherwise the sentence the
  settings write publishes as a side effect. Off a local Mac primary nothing
  is called: the link never runs there.
  """
  @spec apply_enabled(boolean(), keyword()) :: :ok | {:error, String.t()}
  def apply_enabled(on?, opts \\ []) when is_boolean(on?) and is_list(opts) do
    if local_mac_primary?(opts),
      do: switched(on?, provider_call(opts, :apply_enabled, [on?])),
      else: {:error, @needs_primary_sentence}
  end

  defp switched(_on?, {:ok, {:ok, state}}) when state in [:started, :stopped], do: :ok
  defp switched(true, {:ok, {:ok, :not_started}}), do: {:error, @switch_not_started_sentence}
  defp switched(_on?, {:ok, {:error, :not_ready}}), do: {:error, @switch_not_ready_sentence}

  defp switched(on?, reply) do
    Logger.error(
      "management accessories: apply_enabled(#{on?}) answered #{Redaction.format(reply)}"
    )

    {:error, @switch_failed_sentence}
  end

  # -- the status request and its wait -----------------------------------------------

  defp status_request(params, opts) when map_size(params) == 0, do: status(opts)

  defp status_request(params, opts) do
    with :ok <- only(params, ~w(after wait_ms)),
         {:ok, key} <- wait_key(params["after"]),
         {:ok, ms} <- wait_ms(params["wait_ms"]) do
      status_after(key, ms, opts)
    end
  end

  defp wait_key(key) when is_binary(key) do
    if Regex.match?(@key_pattern, key), do: {:ok, key}, else: invalid("after")
  end

  defp wait_key(_key), do: invalid("after")

  defp wait_ms(ms) when is_integer(ms) and ms in 0..@max_wait_ms//1, do: {:ok, ms}
  defp wait_ms(_ms), do: invalid("wait_ms")

  # Two ways to hear a change, both bounded by the wait. The watcher tells its
  # subscribers every change of what the subtree owns (ports, links, calls),
  # at once; and the wait reads again every `@reread_ms` for what it does not
  # own (the call lease, voice readiness, the switch, the store's files),
  # which no process announces. A change between the first read and the
  # subscribe is caught by reading once more right after subscribing.
  defp hold(after_key, wait_ms, opts) do
    watcher = subscribe(opts)
    token = make_ref()
    timer = Keyword.get(opts, :wait_timer, &Process.send_after(self(), &1, &2))
    _timer = timer.({:accessories_wait, token}, wait_ms)
    wait = %{key: after_key, token: token, watcher: watcher, timer: timer, opts: opts}
    answer = reread(wait, @max_rereads)
    unsubscribe(watcher, opts)
    answer
  end

  # A subtree that does not run has no watcher to wake the wait: it answers
  # when the wait runs out. One that runs is monitored, so its end (the switch
  # turned off) answers at once.
  defp subscribe(opts) do
    case provider_call(opts, :subscribe, [self()]) do
      {:ok, {:ok, pid}} when is_pid(pid) -> Process.monitor(pid)
      {:ok, {:error, :not_running}} -> nil
      {:ok, {:error, reason}} -> unsubscribed(reason)
      {:error, _refusal} -> nil
    end
  end

  # The watcher holds a bounded number of waiters; past it a wait answers when
  # its time runs out, as with a link that does not run.
  defp unsubscribed(reason) do
    Logger.warning("management accessories: a status wait was not subscribed: #{inspect(reason)}")
    nil
  end

  # A waiter that answered stops being told; one whose watcher ended has none.
  defp unsubscribe(nil, _opts), do: :ok

  defp unsubscribe(watcher, opts) do
    Process.demonitor(watcher, [:flush])

    case provider_call(opts, :unsubscribe, [self()]) do
      {:ok, :ok} -> :ok
      {:ok, {:error, _not_running}} -> :ok
      {:error, _refusal} -> :ok
    end
  end

  defp held(%{opts: opts}, 0), do: status(opts)

  defp held(%{token: token, watcher: watcher} = wait, rereads) do
    receive do
      {:accessories_changed, _version} -> reread(wait, rereads)
      {:accessories_reread, ^token} -> reread(wait, rereads)
      {:DOWN, ^watcher, :process, _pid, _reason} -> status(wait.opts)
      {:accessories_wait, ^token} -> status(wait.opts)
    end
  end

  # One tick is scheduled at a time, after each read, so a wait woken by the
  # watcher never piles ticks up.
  defp reread(wait, rereads) do
    {:ok, record} = status(wait.opts)

    if record["key"] == wait.key do
      _tick = wait.timer.({:accessories_reread, wait.token}, @reread_ms)
      held(wait, rereads - 1)
    else
      {:ok, record}
    end
  end

  # -- params ----------------------------------------------------------------------

  defp action("accessories.pair.start", params), do: by_path(params, :pair_start)

  defp action("accessories.pair.begin", params) do
    with :ok <- only(params, ~w(path name)),
         {:ok, path} <- path(params),
         {:ok, name} <- optional_name(params) do
      {:ok, {:pair_begin, path, name}}
    end
  end

  defp action("accessories.pair.decide", params) do
    with :ok <- only(params, ~w(path attempt matches)),
         {:ok, path} <- path(params),
         {:ok, attempt} <- attempt(params["attempt"]),
         {:ok, matches?} <- boolean(params, "matches") do
      {:ok, {:pair_decide, path, attempt, matches?}}
    end
  end

  defp action("accessories.pair.cancel", params) do
    with :ok <- only(params, ~w(path attempt)),
         {:ok, path} <- path(params),
         {:ok, attempt} <- optional_attempt(params) do
      {:ok, {:pair_cancel, path, attempt}}
    end
  end

  defp action("accessories.retry", params), do: by_path(params, :retry)
  defp action("accessories.release", params), do: by_path(params, :release)
  defp action("accessories.reconnect", params), do: by_path(params, :reconnect)
  defp action("accessories.forget", params), do: by_id(params, :forget)
  defp action("accessories.revoke", params), do: by_id(params, :revoke)

  defp action("accessories.voice_device.set", params) do
    with :ok <- only(params, ~w(device)), {:ok, device} <- device(params["device"]) do
      {:ok, {:voice_device, device}}
    end
  end

  defp action("accessories.call.start", params), do: by_id(params, :call_start)
  defp action("accessories.call.end", params), do: by_call(params, ~w(), :call_end)
  defp action("accessories.call.interrupt", params), do: by_call(params, ~w(), :call_interrupt)

  defp action("accessories.call.mute", params) do
    with {:ok, {:call_mute, id, call_id}} <- by_call(params, ~w(muted), :call_mute),
         {:ok, muted?} <- boolean(params, "muted") do
      {:ok, {:call_mute, id, call_id, muted?}}
    end
  end

  defp action("accessories.call.task.cancel", params) do
    with {:ok, {:call_task_cancel, id, call_id}} <- by_call(params, ~w(task), :call_task_cancel),
         {:ok, task} <- text(params["task"], @max_task_bytes, "task") do
      {:ok, {:call_task_cancel, id, call_id, task}}
    end
  end

  defp action("accessories.check.start", params) do
    with :ok <- only(params, ~w(accessory_id check seconds)),
         {:ok, id} <- accessory_id(params["accessory_id"]),
         {:ok, check} <- enum(params["check"], @checks, "check"),
         {:ok, seconds} <- check_seconds(check, params) do
      {:ok, {:check_start, id, check, seconds}}
    end
  end

  defp action("accessories.check.stop", params), do: by_id(params, :check_stop)

  defp action("accessories.calibrate", params) do
    with :ok <- only(params, ~w(accessory_id op axis steps)),
         {:ok, id} <- accessory_id(params["accessory_id"]),
         {:ok, op} <- enum(params["op"], @calibrate_ops, "op"),
         {:ok, nudge} <- nudge(op, params) do
      {:ok, {:calibrate, id, op, nudge}}
    end
  end

  defp action("accessories.set", params) do
    with :ok <- only(params, ~w(accessory_id volume brightness motion)),
         {:ok, id} <- accessory_id(params["accessory_id"]),
         {:ok, values} <- settings(params) do
      {:ok, {:set, id, values}}
    end
  end

  defp action(_method, _params), do: invalid("method")

  defp by_path(params, verb) do
    with :ok <- only(params, ~w(path)), {:ok, path} <- path(params), do: {:ok, {verb, path}}
  end

  defp by_id(params, verb) do
    with :ok <- only(params, ~w(accessory_id)),
         {:ok, id} <- accessory_id(params["accessory_id"]),
         do: {:ok, {verb, id}}
  end

  defp by_call(params, extra, verb) do
    with :ok <- only(params, ~w(accessory_id call_id) ++ extra),
         {:ok, id} <- accessory_id(params["accessory_id"]),
         {:ok, call_id} <- text(params["call_id"], @max_call_id_bytes, "call_id") do
      {:ok, {verb, id, call_id}}
    end
  end

  defp only(params, allowed) do
    case Enum.find(Map.keys(params), &(&1 not in allowed)) do
      nil -> :ok
      field -> invalid(field)
    end
  end

  defp path(params), do: text(params["path"], @max_path_bytes, "path")

  defp text(value, max, field) when is_binary(value) do
    if byte_size(value) in 1..max//1, do: {:ok, value}, else: invalid(field)
  end

  defp text(_value, _max, field), do: invalid(field)

  defp optional_name(%{"name" => name}) when is_binary(name) do
    if byte_size(name) in 1..@max_name_bytes//1 and String.printable?(name),
      do: {:ok, name},
      else: invalid("name")
  end

  defp optional_name(%{"name" => _other}), do: invalid("name")
  defp optional_name(_params), do: {:ok, nil}

  defp attempt(value) when is_binary(value) do
    if Regex.match?(@hex32, value), do: {:ok, value}, else: invalid("attempt")
  end

  defp attempt(_value), do: invalid("attempt")

  defp optional_attempt(%{"attempt" => value}), do: attempt(value)
  defp optional_attempt(_params), do: {:ok, nil}

  defp accessory_id(value) when is_binary(value) do
    if Regex.match?(@hex64, value), do: {:ok, value}, else: invalid("accessory_id")
  end

  defp accessory_id(_value), do: invalid("accessory_id")

  defp device("desktop"), do: {:ok, :desktop}

  defp device("accessory:" <> id) do
    if Regex.match?(@hex64, id), do: {:ok, {:accessory, id}}, else: invalid("device")
  end

  defp device(_value), do: invalid("device")

  defp boolean(params, field) do
    case Map.fetch(params, field) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      _missing_or_not -> invalid(field)
    end
  end

  defp enum(value, table, field) do
    case Map.fetch(table, value) do
      {:ok, atom} -> {:ok, atom}
      :error -> invalid(field)
    end
  end

  defp check_seconds(:mic, %{"seconds" => seconds}) when is_integer(seconds) and seconds in 1..10,
    do: {:ok, seconds}

  defp check_seconds(:mic, %{"seconds" => _bad}), do: invalid("seconds")
  defp check_seconds(:mic, _params), do: {:ok, @default_mic_seconds}
  defp check_seconds(_check, %{"seconds" => _given}), do: invalid("seconds")
  defp check_seconds(_check, _params), do: {:ok, nil}

  defp nudge(:nudge, %{"axis" => axis, "steps" => steps})
       when is_integer(steps) and steps in -64..64 and steps != 0 do
    with {:ok, axis} <- enum(axis, @axes, "axis"), do: {:ok, %{axis: axis, steps: steps}}
  end

  defp nudge(:nudge, %{"axis" => _axis}), do: invalid("steps")
  defp nudge(:nudge, _params), do: invalid("axis")
  defp nudge(_op, %{"axis" => _axis}), do: invalid("axis")
  defp nudge(_op, %{"steps" => _steps}), do: invalid("steps")
  defp nudge(_op, _params), do: {:ok, nil}

  defp settings(params) do
    values = Map.take(params, ~w(volume brightness motion))

    cond do
      values == %{} -> invalid_sentence("volume", @set_nothing_sentence)
      bad = Enum.find(values, &(not setting?(&1))) -> invalid(elem(bad, 0))
      true -> {:ok, Map.new(values, fn {key, value} -> {String.to_existing_atom(key), value} end)}
    end
  end

  defp setting?({"motion", value}), do: is_boolean(value)
  defp setting?({_level, value}), do: is_integer(value) and value in 0..100

  defp invalid(field), do: {:error, :invalid_params, %{"field" => field}}

  # -- where an action is answered ---------------------------------------------------

  # Off a local Mac primary nothing runs. Forget and Revoke erase a record
  # while the link is off, as `mobile.devices.revoke` does the paired-device
  # file; everything else needs the link running.
  defp admitted(action, opts) do
    facts = facts(opts)

    cond do
      facts.place != :local -> unavailable(@needs_primary_sentence)
      record_only?(action) -> :ok
      not facts.enabled -> unavailable(@off_sentence)
      not running?(facts) -> unavailable(@not_running_sentence)
      true -> :ok
    end
  end

  defp record_only?({verb, _id}) when verb in [:forget, :revoke], do: true
  defp record_only?({:voice_device, _device}), do: true
  defp record_only?(_action), do: false

  # -- acting ----------------------------------------------------------------------

  defp act({:voice_device, device}, opts), do: set_voice_device(device, opts)

  defp act({verb, id} = action, opts) when verb in [:forget, :revoke],
    do: remove(action, id, opts)

  defp act({:call_start, id}, opts), do: answered(provider_action(opts, :call_start, [id]), opts)

  # Only a Live or Grok task the call still runs can be cancelled; the view
  # the app drew the button from says which.
  defp act({:call_task_cancel, id, call_id, task}, opts) do
    if cancellable?(task, opts),
      do: answered(provider_action(opts, :call_task_cancel, [id, call_id, task]), opts),
      else: refused(:not_cancellable, opts)
  end

  defp act(action, opts) do
    {function, args} = provider_args(action)
    answered(provider_action(opts, function, args), opts)
  end

  defp provider_args({:pair_start, path}), do: {:pair_start, [path]}
  defp provider_args({:pair_begin, path, name}), do: {:pair_begin, [path, name]}

  defp provider_args({:pair_decide, path, attempt, matches?}),
    do: {:pair_decide, [path, attempt, matches?]}

  defp provider_args({:pair_cancel, path, attempt}), do: {:pair_cancel, [path, attempt]}
  defp provider_args({:retry, path}), do: {:retry, [path]}
  defp provider_args({:release, path}), do: {:release, [path]}
  defp provider_args({:reconnect, path}), do: {:reconnect, [path]}
  defp provider_args({:call_end, id, call_id}), do: {:call_end, [id, call_id]}
  defp provider_args({:call_interrupt, id, call_id}), do: {:call_interrupt, [id, call_id]}
  defp provider_args({:call_mute, id, call_id, muted?}), do: {:call_mute, [id, call_id, muted?]}

  defp provider_args({:check_start, id, check, seconds}), do: {:check_start, [id, check, seconds]}
  defp provider_args({:check_stop, id}), do: {:check_stop, [id]}
  defp provider_args({:calibrate, id, op, nudge}), do: {:calibrate, [id, op, nudge]}
  defp provider_args({:set, id, values}), do: {:set, [id, values]}

  defp cancellable?(task, opts) do
    {:ok, status} = status(opts)

    case status["call"] do
      %{"tasks" => tasks} -> Enum.any?(tasks, &(&1["task"] == task and &1["cancellable"]))
      nil -> true
    end
  end

  defp provider_action(opts, function, args) do
    case provider_call(opts, function, args) do
      {:ok, reply} -> reply
      {:error, _refusal} = refused -> refused
    end
  end

  # A running link forgets through its own store writer; one that is off has
  # no writer, and the record is erased here.
  defp remove({verb, id}, id, opts) do
    reply =
      if state(facts(opts)) == :on,
        do: provider_action(opts, verb, [id]),
        else: Store.forget(home(opts), id)

    answered(reply, opts)
  end

  defp set_voice_device(device, opts) do
    facts = facts(opts)

    if call_active?(facts),
      do: unavailable(@device_locked_sentence),
      else: saved_voice_device(put_voice_device(opts).(home(opts), device), device, opts)
  end

  # `:put_voice_device` stands in for the store's write in a test.
  defp put_voice_device(opts),
    do: Keyword.get(opts, :put_voice_device, &Store.put_voice_device/2)

  defp saved_voice_device(:ok, _device, opts) do
    # The watcher's waiters are woken so an app waiting on the key redraws;
    # a link that does not run has none.
    case provider_call(opts, :touch, []) do
      {:ok, :ok} -> status(opts)
      {:ok, {:error, :not_running}} -> status(opts)
      {:error, _refusal} -> status(opts)
    end
  end

  defp saved_voice_device({:error, :unknown_accessory}, _device, _opts),
    do: invalid_sentence("device", @unknown_sentence)

  defp saved_voice_device({:error, reason}, device, _opts) do
    Logger.error(
      "management accessories: the voice device #{inspect(device)} could not be saved: " <>
        Redaction.format(reason)
    )

    unavailable(@device_unsaved_sentence)
  end

  defp answered(:ok, opts), do: status(opts)
  defp answered({:ok, _started}, opts), do: status(opts)
  defp answered({:error, reason}, opts), do: refused(reason, opts)

  defp refused({:refused, code}, _opts) when is_binary(code), do: call_refused(code)
  defp refused(:not_running, opts), do: unavailable(view(facts(opts))["sentence"])
  defp refused(:not_present, _opts), do: invalid_sentence("path", @no_port_sentence)
  defp refused(:released, _opts), do: invalid_sentence("path", @released_sentence)

  defp refused(reason, _opts) when reason in [:not_linked, :not_pairing, :no_pairing],
    do: invalid_sentence("path", @no_pairing_sentence)

  defp refused(:not_unenrolled, _opts), do: unavailable(@not_answered_sentence)
  defp refused(:already_paired, _opts), do: unavailable(@already_paired_sentence)
  defp refused(:pairing_open, _opts), do: unavailable(@pairing_open_sentence)
  defp refused(:stale_attempt, _opts), do: changed(@stale_attempt_sentence)
  defp refused(:unknown_accessory, _opts), do: invalid_sentence("accessory_id", @unknown_sentence)

  defp refused(:not_attached, _opts),
    do: invalid_sentence("accessory_id", @not_attached_sentence)

  defp refused(reason, _opts) when reason in [:no_call, :stale_call],
    do: changed(@stale_call_sentence)

  defp refused(:call_active, _opts), do: unavailable(@busy_call_sentence)
  defp refused({:capability_missing, _cap}, _opts), do: unavailable(@incapable_sentence)
  defp refused(:not_cancellable, _opts), do: invalid_sentence("task", @task_sentence)
  defp refused({:unavailable, _capability}, _opts), do: unavailable(@failed_sentence)

  defp refused(reason, _opts) do
    Logger.error("management accessories: the link refused: #{Redaction.format(reason)}")
    unavailable(@failed_sentence)
  end

  defp call_refused(code) do
    {:error, :unavailable,
     %{"capability" => @capability, "code" => code, "sentence" => call_sentence(code)}}
  end

  defp unavailable(sentence),
    do: {:error, :unavailable, %{"capability" => @capability, "sentence" => sentence}}

  defp invalid_sentence(field, sentence),
    do: {:error, :invalid_params, %{"field" => field, "sentence" => sentence}}

  defp changed(sentence), do: {:error, :changed, %{"sentence" => sentence}}

  # -- the provider ----------------------------------------------------------------

  # One call to the provider, by name, with `:provider_opts` as its own seams.
  # A provider nobody registered, or one without the function, is the
  # capability being absent; a call that exits names the other app's
  # internals, which stay in the log.
  defp provider_call(opts, function, args) do
    provider = Keyword.get_lazy(opts, :provider, &registered_provider/0)
    args = args ++ [Keyword.get(opts, :provider_opts, [])]

    if callable?(provider, function, length(args)),
      do: invoke(provider, function, args),
      else: {:error, {:unavailable, @capability}}
  end

  defp registered_provider,
    do: Application.get_env(:fermix_core, :accessories_management_provider)

  defp callable?(provider, function, arity) when is_atom(provider) and not is_nil(provider),
    do: Code.ensure_loaded?(provider) and function_exported?(provider, function, arity)

  defp callable?(_provider, _function, _arity), do: false

  defp invoke(provider, function, args) do
    {:ok, apply(provider, function, args)}
  catch
    :exit, reason ->
      Logger.error("management accessories: #{function} exited: #{Redaction.format(reason)}")
      {:error, {:unavailable, @capability}}
  end

  # -- the facts -------------------------------------------------------------------

  defp facts(opts) do
    home = home(opts)

    %{
      place: if(local_mac_primary?(opts), do: :local, else: :elsewhere),
      enabled: Keyword.get_lazy(opts, :enabled?, &Config.enabled?/0),
      provider: provider_status(opts),
      voice: Keyword.get_lazy(opts, :readiness, &Readiness.voice/0),
      records: Keyword.get_lazy(opts, :records, fn -> Store.list(home) end),
      voice_device:
        Keyword.get_lazy(opts, :voice_device, fn -> Store.load_voice_device(home) end),
      call_holder: Keyword.get_lazy(opts, :call_holder, &call_holder/0),
      realtime: Keyword.get_lazy(opts, :realtime_config, &RealtimeConfig.current/0)
    }
  end

  defp local_mac_primary?(opts) do
    role = Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)
    os = Keyword.get_lazy(opts, :os_type, &:os.type/0)
    role.role == :primary and os == {:unix, :darwin}
  end

  defp home(opts), do: Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)

  defp call_holder do
    if Process.whereis(CallLease), do: CallLease.holder(CallLease), else: :none
  end

  defp provider_status(opts) do
    case provider_call(opts, :status, []) do
      {:ok, {:ok, %{} = status}} -> status
      {:ok, other} -> unexpected_status(other)
      {:error, _refusal} -> %{running: false, watcher: nil, last_calls: %{}}
    end
  end

  defp unexpected_status(reply) do
    Logger.error("management accessories: status answered #{Redaction.format(reply)}")
    %{running: false, watcher: nil, last_calls: %{}}
  end

  defp running?(%{provider: %{running: true, watcher: %{}}}), do: true
  defp running?(_facts), do: false

  defp call_active?(facts), do: facts.call_holder != :none or live_call(facts) != nil

  defp live_call(facts) do
    Enum.find_value(entries(facts), fn
      %{link: %{call: %{} = call} = link} -> {link, call}
      _entry -> nil
    end)
  end

  defp entries(%{provider: %{watcher: %{ports: ports}}}) when is_list(ports), do: ports
  defp entries(_facts), do: []

  # -- the view --------------------------------------------------------------------

  defp view(facts) do
    state = state(facts)
    records = records(facts)
    ports = if state == :on, do: port_views(facts, records), else: []

    %{
      "state" => Atom.to_string(state),
      "sentence" => top_sentence(state, facts),
      "enabled" => facts.enabled,
      "kinds" => Enum.map(Attach.kinds(), &kind_view/1),
      "voice" => voice_view(facts),
      "voice_device" => voice_device_view(facts),
      "ports" => ports,
      "ports_sentence" => if(state == :on and ports == [], do: @no_ports_sentence),
      "accessories" => Enum.map(records, &accessory_view(&1, state, facts)),
      "pairing" => if(state == :on, do: pairing_view(facts), else: nil),
      "call" => if(state == :on, do: call_view(facts), else: nil)
    }
    |> keyed()
  end

  defp keyed(view) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(view, [:deterministic]))
    Map.put(view, "key", Base.encode16(binary_part(digest, 0, 8), case: :lower))
  end

  defp state(%{place: :elsewhere}), do: :needs_local_primary
  defp state(%{enabled: false}), do: :off
  defp state(facts), do: if(running?(facts), do: :on, else: :not_running)

  defp top_sentence(:needs_local_primary, _facts), do: @needs_primary_sentence
  # A robot left chosen when accessories were turned off stays chosen, and is
  # said: the Mac's own call is refused for it until the owner chooses again.
  defp top_sentence(:off, %{voice_device: {:ok, {:accessory, _id}}}),
    do: VoiceDevice.off_but_chosen_sentence()

  defp top_sentence(:off, _facts), do: @off_sentence
  defp top_sentence(:not_running, _facts), do: @not_running_sentence

  defp top_sentence(:on, facts) do
    case facts.records do
      {:ok, []} -> @connect_sentence
      {:ok, _records} -> @on_sentence
      {:error, _reason} -> @records_sentence
    end
  end

  defp records(%{records: {:ok, records}}), do: Enum.sort_by(records, & &1.enrolled_at, DateTime)

  defp records(%{records: {:error, reason}}) do
    Logger.error("management accessories: the pairing store is unreadable: #{inspect(reason)}")
    []
  end

  defp kind_view(kind) do
    {:ok, meta} = Attach.kind_metadata(kind)
    {wire_min, wire_max} = meta.firmware_range

    %{
      "kind" => kind,
      "name" => meta.display_name,
      "wire_min" => wire_min,
      "wire_max" => wire_max,
      "install_guide" => meta.install_guide
    }
  end

  defp voice_view(facts) do
    config = facts.realtime
    code = voice_code(facts.voice)

    %{
      "ready" => code == nil,
      "code" => code,
      "sentence" => Map.fetch!(@voice_sentences, code),
      "engine" => config.engine,
      "engine_label" => Voice.engine_label(config.engine),
      "model" => config.model,
      "voice" => config.voice
    }
  end

  defp voice_code(:ready), do: nil
  defp voice_code({:not_ready, code}) when is_map_key(@voice_sentences, code), do: code

  # An unreadable choice is its own device, `unreadable`, never a guess at
  # one: an app routes a call on it, and every call is refused for it until
  # the owner chooses again (`VoiceDevice`), which stays open as any change of
  # device does while no call runs.
  defp voice_device_view(facts) do
    active? = call_active?(facts)

    {device, id} =
      case facts.voice_device do
        {:ok, :desktop} -> {"desktop", nil}
        {:ok, {:accessory, id}} -> {"accessory:" <> id, id}
        {:error, _reason} -> {"unreadable", nil}
      end

    %{
      "device" => device,
      "accessory_id" => id,
      "changeable" => not active?,
      "sentence" => device_sentence(active?, facts)
    }
  end

  defp device_sentence(true, _facts), do: @device_locked_sentence

  defp device_sentence(false, %{voice_device: {:error, _reason}}),
    do: VoiceDevice.unreadable_sentence()

  defp device_sentence(false, %{enabled: false, voice_device: {:ok, {:accessory, _id}}}),
    do: VoiceDevice.off_but_chosen_sentence()

  defp device_sentence(false, _facts), do: nil

  # -- ports -----------------------------------------------------------------------

  defp port_views(facts, _records) do
    selected = get_in(facts.provider, [:watcher, :selected])
    Enum.map(entries(facts), &port_view(&1, &1.path == selected))
  end

  defp port_view(entry, selected?) do
    {status, update} = port_status(entry)
    link = entry.link || %{}
    # A port is released only once its call has ended (the robot's own row
    # says so the same way).
    actions = port_actions(status, update) -- if(link[:call], do: [:release], else: [])

    %{
      "path" => entry.path,
      "serial" => entry.serial,
      "status" => Atom.to_string(status),
      "selected" => selected?,
      "accessory_id" => if(status == :attached, do: link[:accessory_id]),
      "kind" => link[:kind],
      "firmware" => link[:firmware],
      "update" => update && Atom.to_string(update),
      "install_guide" => if(:open_install_guide in actions, do: guide(link[:kind])),
      "retrying" => match?(%{waiting?: true}, entry.busy),
      "sentence" => port_sentence(status, update, link),
      "actions" => Enum.map(actions, &Atom.to_string/1)
    }
  end

  # A port that gave no Fermix answer named no kind, and any Espressif board
  # looks the same on USB, so its guide is the one kind's this daemon pairs.
  # A second kind needs its own answer here (which guide an unknown board
  # gets), not a silent default.
  @unanswered_port_kind "stackchan"

  defp guide(nil), do: guide(@unanswered_port_kind)

  defp guide(kind) do
    {:ok, meta} = Attach.kind_metadata(kind)
    meta.install_guide
  end

  defp port_status(%{state: :linked, link: link}), do: linked_status(link)
  defp port_status(%{state: :no_answer}), do: {:needs_firmware, nil}

  defp port_status(%{state: state})
       when state in [:busy, :unrelated, :vanished, :released, :failed],
       do: {state, nil}

  defp linked_status(nil), do: {:attaching, nil}

  defp linked_status(%{enrollment: %{phase: phase}})
       when phase in [:begun, :offered, :revealed, :committing],
       do: {:pairing, nil}

  defp linked_status(%{phase: :attached}), do: {:attached, nil}
  defp linked_status(%{phase: phase}) when phase in [:hello, :proving], do: {:attaching, nil}
  defp linked_status(%{phase: :unenrolled, mode: :pairing}), do: {:unpaired, nil}
  defp linked_status(%{phase: :unenrolled}), do: {:not_paired, nil}
  defp linked_status(%{phase: :refused} = link), do: refused_status(link)

  @not_paired_refusals [
    :unknown_accessory,
    :bad_proof,
    {:accessory, :unknown_host},
    {:accessory, :bad_proof},
    {:accessory, :unknown_accessory}
  ]

  defp refused_status(%{refusal: :wire_version, wire: wire}) when is_integer(wire),
    do: {:incompatible, host_side(wire)}

  defp refused_status(%{refusal: {:accessory, :wire_version}, refused_range: {low, high}})
       when is_integer(low) and is_integer(high),
       do: {:incompatible, accessory_side(low, high)}

  defp refused_status(%{refusal: :capability_missing}), do: {:incompatible, :firmware}
  defp refused_status(%{refusal: :unsupported_kind}), do: {:incompatible, :fermix}

  defp refused_status(%{refusal: refusal}) when refusal in @not_paired_refusals,
    do: {:not_paired, nil}

  defp refused_status(_link), do: {:failed, nil}

  # PROTOCOL.md (accessory), *Versioning*: an accessory whose version is above
  # the host's window needs Fermix updated; below it, its firmware.
  defp host_side(wire) do
    {_low, high} = Control.supported_wire_range()
    if wire > high, do: :fermix, else: :firmware
  end

  defp accessory_side(low, _high) when is_integer(low) do
    {_host_low, host_high} = Control.supported_wire_range()
    if low > host_high, do: :fermix, else: :firmware
  end

  defp port_actions(:unrelated, _update), do: [:pair]
  defp port_actions(:unpaired, _update), do: [:pair_begin, :pair_cancel]
  defp port_actions(:pairing, _update), do: [:pair_cancel]
  defp port_actions(:attached, _update), do: [:release]
  defp port_actions(:busy, _update), do: [:retry]
  defp port_actions(:needs_firmware, _update), do: [:open_install_guide, :retry]
  defp port_actions(:incompatible, :firmware), do: [:open_install_guide, :release]
  defp port_actions(:incompatible, :fermix), do: [:update_fermix, :release]
  defp port_actions(:not_paired, _update), do: [:pair]
  defp port_actions(:released, _update), do: [:reconnect]
  defp port_actions(:failed, _update), do: [:retry]
  defp port_actions(_status, _update), do: []

  defp port_sentence(:incompatible, update, _link), do: Map.fetch!(@update_sentences, update)
  defp port_sentence(:pairing, _update, link), do: enrollment_sentence(link.enrollment)
  defp port_sentence(status, _update, _link), do: Map.fetch!(@port_sentences, status)

  # -- accessories -----------------------------------------------------------------

  defp accessory_view(%Record{} = record, state, facts) do
    entry = if state == :on, do: entry_for(record, facts)
    connection = if state == :on, do: connection(entry), else: :off
    link = if connection == :attached, do: entry.link, else: nil
    selected? = facts.voice_device == {:ok, {:accessory, record.accessory_id}}

    %{
      "accessory_id" => record.accessory_id,
      "short_id" => short_id(record.accessory_id),
      "name" => record.name,
      "kind" => record.kind,
      "enrolled_at" => DateTime.to_iso8601(record.enrolled_at),
      "connection" => Atom.to_string(connection),
      "path" => entry && entry.path,
      "gen" => link && link.gen,
      "firmware" => entry && entry.link && entry.link[:firmware],
      "capabilities" => capabilities(link),
      "state" => state_view(link),
      "calibration_sentence" => calibration_sentence(link),
      "fault" => link && link[:fault],
      "diag" => diag_view(link),
      "check" => check_view(link),
      "selected" => selected?,
      "sentence" => accessory_sentence(connection, entry, link, state),
      "actions" => accessory_actions(connection, link, selected?, state, facts),
      "last_call" => last_call_view(Map.get(facts.provider.last_calls, record.accessory_id))
    }
  end

  # The robot's own `diag.counters` (PROTOCOL.md (accessory), *Diagnostics*),
  # since its boot, as it last reported them this attach: the closed set of
  # counters, each a u32, or null before a report and off an attached link.
  @diag_counters ~w(uptime_s frames_rx frames_tx crc_errors resync_bytes pcm_seq_gaps
                    mic_overflows spk_underflows)a

  defp diag_view(%{diag: %{} = diag}),
    do: Map.new(@diag_counters, fn name -> {Atom.to_string(name), Map.fetch!(diag, name)} end)

  defp diag_view(_link), do: nil

  # The port its link attached it on, else the port its serial names.
  defp entry_for(record, facts) do
    entries = entries(facts)

    Enum.find(entries, &match?(%{link: %{accessory_id: id}} when id == record.accessory_id, &1)) ||
      Enum.find(entries, &(record.port_hint != nil and &1.serial == record.port_hint))
  end

  defp connection(nil), do: :unplugged
  defp connection(%{state: :linked} = entry), do: linked_connection(port_status(entry))
  defp connection(%{state: :vanished}), do: :unplugged
  defp connection(%{state: state}) when state in [:busy, :released, :failed], do: state
  defp connection(%{state: _other}), do: :attaching

  defp linked_connection({:attached, _update}), do: :attached
  defp linked_connection({:incompatible, _update}), do: :incompatible

  defp linked_connection({status, _update}) when status in [:not_paired, :unpaired],
    do: :not_paired

  defp linked_connection({:failed, _update}), do: :failed
  defp linked_connection({_attaching_or_pairing, _update}), do: :attaching

  defp short_id(id) do
    id |> binary_part(0, 16) |> String.graphemes() |> Enum.chunk_every(4) |> Enum.join(" ")
  end

  defp capabilities(nil), do: []

  defp capabilities(%{caps: caps}) when is_list(caps),
    do: for(cap <- @host_caps, cap in caps, do: Atom.to_string(cap))

  defp state_view(%{accessory_state: %{} = state}) do
    Map.new(~w(battery power brownout volume brightness motion calibration)a, fn key ->
      {Atom.to_string(key), Map.get(state, key)}
    end)
  end

  defp state_view(_link), do: nil

  # A robot without head motion reports `absent` and has no sentence to show.
  defp calibration_sentence(%{accessory_state: %{calibration: calibration}}),
    do: Map.get(@calibration_sentences, calibration)

  defp calibration_sentence(_link), do: nil

  defp check_view(%{check: %{} = check}) do
    %{
      "check" => Atom.to_string(check.check),
      "status" => Atom.to_string(check.status),
      "code" => check.code,
      "level" => check.level
    }
  end

  defp check_view(_link), do: nil

  defp accessory_sentence(:off, _entry, _link, state), do: top_sentence(state, nil)
  defp accessory_sentence(:attached, _entry, link, _state), do: attached_sentence(link)

  defp accessory_sentence(connection, entry, _link, _state)
       when connection in [:busy, :incompatible, :released, :not_paired] do
    {status, update} = port_status(entry)
    port_sentence(port_status_for(connection, status), update, entry.link || %{})
  end

  defp accessory_sentence(connection, _entry, _link, _state),
    do: Map.fetch!(@connection_sentences, connection)

  defp port_status_for(:not_paired, _status), do: :not_paired
  defp port_status_for(_connection, status), do: status

  defp attached_sentence(%{fault: fault}) when is_binary(fault), do: fault_sentence(fault)

  defp attached_sentence(%{accessory_state: %{power: power}}) when power in ["low", "critical"],
    do: @power_sentence

  defp attached_sentence(_link), do: Map.fetch!(@connection_sentences, :attached)

  # The fault is the robot's own token, backticked: a literal, never prose.
  defp fault_sentence(fault), do: "StackChan reports a problem: `#{fault}`. Check its screen."

  defp accessory_actions(_connection, _link, _selected?, :needs_local_primary, _facts), do: []
  defp accessory_actions(:off, _link, _selected?, _state, _facts), do: words([:forget, :revoke])

  defp accessory_actions(connection, link, selected?, _state, facts) do
    quiet? = not call_active?(facts)
    select = if quiet? and not selected?, do: [:select], else: []

    (connection_actions(connection, link, quiet?, facts) ++ select ++ [:forget, :revoke])
    |> Enum.sort_by(&action_rank/1)
    |> words()
  end

  defp connection_actions(:attached, link, quiet?, facts) do
    call = if quiet? and callable?(link, facts), do: [:start_call], else: []
    calibrate = if :motion in link.caps, do: [:calibrate], else: []
    if quiet?, do: call ++ [:check] ++ calibrate ++ [:release], else: []
  end

  defp connection_actions(:released, _link, _quiet?, _facts), do: [:reconnect]

  defp connection_actions(connection, _link, _quiet?, _facts) when connection in [:busy, :failed],
    do: [:retry]

  defp connection_actions(:not_paired, _link, _quiet?, _facts), do: [:pair]
  defp connection_actions(:incompatible, _link, _quiet?, _facts), do: [:release]
  defp connection_actions(_connection, _link, _quiet?, _facts), do: []

  defp callable?(link, facts) do
    voice_code(facts.voice) == nil and :mic in link.caps and :speaker in link.caps and
      not match?(%{accessory_state: %{power: power}} when power in ["low", "critical"], link)
  end

  @action_order ~w(start_call select check calibrate pair retry reconnect release forget revoke)a
  defp action_rank(action), do: Enum.find_index(@action_order, &(&1 == action))
  defp words(actions), do: Enum.map(actions, &Atom.to_string/1)

  defp last_call_view(nil), do: nil

  defp last_call_view(%{reason: reason} = last) do
    %{
      "call_id" => last.call_id,
      "reason" => reason,
      "sentence" => call_sentence(reason),
      "ended_at" => DateTime.to_iso8601(last.ended_at)
    }
  end

  defp call_sentence(reason) do
    cond do
      Map.has_key?(@call_sentences, reason) -> Map.fetch!(@call_sentences, reason)
      Map.has_key?(@voice_sentences, reason) -> Map.fetch!(@voice_sentences, reason)
      reason == "power_too_low" -> @power_sentence
      true -> @call_ended_sentence
    end
  end

  # -- pairing ---------------------------------------------------------------------

  defp pairing_view(facts) do
    Enum.find_value(entries(facts), fn
      %{link: %{enrollment: %{} = enrollment}} = entry -> enrollment_view(entry.path, enrollment)
      _entry -> nil
    end)
  end

  defp enrollment_view(path, e) do
    %{
      "path" => path,
      "attempt" => e.attempt,
      "round" => e.round,
      "max_rounds" => @max_rounds,
      "phase" => Atom.to_string(e.phase),
      "code" => e.code,
      "accessory_confirmed" => e.accessory_confirmed?,
      "owner_confirmed" => e.owner_confirmed?,
      "closed_reason" => e.closed_reason && Atom.to_string(e.closed_reason),
      "accessory_id" => if(e.phase == :done, do: Map.get(e, :accessory_id)),
      "expires_at" => expires_at(e),
      "sentence" => enrollment_sentence(e)
    }
  end

  defp expires_at(%{phase: phase, expires_at: %DateTime{} = at})
       when phase in [:begun, :offered, :revealed],
       do: DateTime.to_iso8601(at)

  defp expires_at(_enrollment), do: nil

  defp enrollment_sentence(%{phase: :closed, closed_reason: reason}),
    do: Map.fetch!(@closed_sentences, reason)

  defp enrollment_sentence(%{phase: phase}), do: Map.fetch!(@pairing_sentences, phase)

  # -- the call --------------------------------------------------------------------

  defp call_view(facts) do
    case live_call(facts) do
      {link, %{view: %{} = view} = call} -> call_projection(link, call, view)
      _none_or_unseen -> nil
    end
  end

  defp call_projection(link, call, view) do
    %{
      "accessory_id" => link.accessory_id,
      "call_id" => call.call_id,
      "source" => Atom.to_string(call.source),
      "phase" => Atom.to_string(call.phase),
      "phase_sentence" => Map.get(@phase_sentences, call.phase),
      "state" => view.state,
      "muted" => view.muted_by != nil,
      "muted_by" => view.muted_by && Atom.to_string(view.muted_by),
      "engine" => view.engine,
      "engine_label" => Voice.engine_label(view.engine),
      "model" => view.model,
      "voice" => view.voice,
      "call_uuid" => view.call_uuid,
      "conversation" => view.conversation,
      "started_at" => view.started_at && DateTime.to_iso8601(view.started_at),
      "transcript" => Enum.map(view.transcript, &line_view/1),
      "tasks" => Enum.map(view.tasks, &task_view(&1, view.engine)),
      "usage" => usage_view(view.usage)
    }
  end

  defp line_view(line),
    do: %{"speaker" => Atom.to_string(line.speaker), "text" => line.text, "final" => line.final?}

  defp task_view(task, engine) do
    %{
      "task" => task.task,
      "revision" => task.revision,
      "status" => task.status,
      "summary" => task.summary,
      "in_chat" => task.in_chat?,
      "cancellable" =>
        task.status == "running" and
          RealtimeConfig.hands_off_tasks?(%RealtimeConfig{engine: engine})
    }
  end

  defp usage_view(nil), do: nil

  defp usage_view(usage) do
    %{
      "cost_cents" => usage.cost_cents,
      "voice_seconds" => usage.voice_seconds,
      "accounting" => usage.accounting
    }
  end

  @doc false
  @spec token?(term()) :: boolean()
  def token?(value), do: is_binary(value) and Regex.match?(@token, value)
end
