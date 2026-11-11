defmodule FermixChannels.Desktop.InvokeTest do
  # M97 §6.2, §6.3: what this computer does with each request its server
  # sends, with the link stood in for. Each answer the computer sends comes
  # to the test as `{:sent, event, payload}`; each timer it sets as
  # `{:timer, message, delay}`, delivered by hand; its clock is the test's.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.Invoke
  alias FermixChannels.Desktop.Invoke.Admission
  alias FermixCore.Computers.Journal
  alias FermixCore.Computers.Switches
  alias FermixCore.Sandbox.Config
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @start ~U[2031-06-08 12:00:00.000Z]

  # A read that runs until the test says how it ends.
  defmodule Wait do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :wait
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["wait"]
    @impl true
    def effect?(_op), do: false
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate("wait", %{"name" => name}) when is_binary(name), do: :ok
    def validate("wait", _args), do: {:error, "Wait needs a name."}
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 200_000}
    @impl true
    def admit(_op, _args, _context), do: :ok

    @impl true
    def run("wait", %{"name" => name}, part, context) do
      test = :persistent_term.get({__MODULE__, context.home})
      send(test, {:running, name, self(), part})

      receive do
        {:finish, result} -> result
      after
        30_000 -> {:failed, "The test never finished it."}
      end
    end

    @impl true
    def target("wait", %{"name" => name}), do: "wait #{name}"
  end

  # An effect: it writes a file under the home.
  defmodule Touch do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :touch
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["touch"]
    @impl true
    def effect?(_op), do: true
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate(_op, %{"name" => name}) when is_binary(name), do: :ok
    def validate(_op, _args), do: {:error, "Touch needs a name."}
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 0}

    @impl true
    def admit(_op, _args, %{origin: origin}) do
      if origin in [:chat, :voice],
        do: :ok,
        else: {:refused, :not_attended, "Touch runs only while you are in the conversation."}
    end

    @impl true
    def run("touch", %{"name" => name}, nil, context) do
      :ok = File.write(Path.join(context.home, name), "touched")
      {:ok, %{"touched" => name}, nil}
    end

    @impl true
    def target("touch", %{"name" => name}), do: "touch #{name}"
  end

  # A long-lived read of another offer, as a Messages watch is: it runs until
  # the test says how it ends.
  defmodule Watch do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :watch
    @impl true
    def offer, do: :imessage
    @impl true
    def ops, do: ["watch"]
    @impl true
    def effect?(_op), do: false
    @impl true
    def long_lived?(_op), do: true
    @impl true
    def validate("watch", %{"name" => name}) when is_binary(name), do: :ok
    def validate("watch", _args), do: {:error, "Watch needs a name."}
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 0}
    @impl true
    def admit(_op, _args, _context), do: :ok

    @impl true
    def run("watch", %{"name" => name}, nil, context) do
      test = :persistent_term.get({Wait, context.home})
      send(test, {:running, name, self(), nil})

      receive do
        {:finish, result} -> result
      after
        30_000 -> {:failed, "The test never finished it."}
      end
    end

    @impl true
    def target("watch", %{"name" => name}), do: "watch #{name}"
  end

  # A read whose own rules wait for the test, as a probe of a folder on a
  # network mount that stopped answering does.
  defmodule Probing do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :probing
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["probe"]
    @impl true
    def effect?(_op), do: false
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate("probe", %{"name" => name}) when is_binary(name), do: :ok
    def validate("probe", _args), do: {:error, "Probe needs a name."}
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 0}

    @impl true
    def admit("probe", %{"name" => name}, context) do
      test = :persistent_term.get({Wait, context.home})
      send(test, {:admitting, name, self()})

      receive do
        {:admit, answer} -> answer
      after
        30_000 -> {:refused, :unavailable, "The test never admitted it."}
      end
    end

    @impl true
    def run("probe", %{"name" => name}, nil, _context), do: {:ok, %{"probed" => name}, nil}

    @impl true
    def target("probe", %{"name" => name}), do: "probe #{name}"
  end

  # A read whose own cancel never answers in time, as a screen seat busy
  # starting its helper did.
  defmodule Stubborn do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :stubborn
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["hold"]
    @impl true
    def effect?(_op), do: false
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate("hold", %{"name" => name}) when is_binary(name), do: :ok
    def validate("hold", _args), do: {:error, "Hold needs a name."}
    @impl true
    def bounds(_op), do: %{result_bytes: 1_024, part_bytes: 0}
    @impl true
    def admit(_op, _args, _context), do: :ok

    @impl true
    def run("hold", %{"name" => name}, nil, context) do
      test = :persistent_term.get({Wait, context.home})
      send(test, {:running, name, self(), nil})

      receive do
        {:finish, result} -> result
      after
        30_000 -> {:failed, "The test never finished it."}
      end
    end

    @impl true
    def cancel("hold", _pid), do: exit({:timeout, {GenServer, :call, [:a_seat, :close, 5_000]}})

    @impl true
    def target("hold", %{"name" => name}), do: "hold #{name}"
  end

  setup do
    home = SafeRm.make_tmp_dir!("desktop_invoke")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :persistent_term.put({Wait, home}, self())
    on_exit(fn -> :persistent_term.erase({Wait, home}) end)

    test = self()
    suffix = System.unique_integer([:positive])
    switches = start_supervised!({Agent, fn -> Switches.only([:files]) end}, id: :switches)
    clock = start_supervised!({Agent, fn -> @start end}, id: :clock)
    epoch = start_supervised!({Agent, fn -> {:ok, 3} end}, id: :epoch)
    name = :"desktop_invoke_#{suffix}"

    opts = [
      name: name,
      home: home,
      switches: fn -> Agent.get(switches, & &1) end,
      sandbox: fn -> Config.normalize(mode: :strict, home: home, os_home: home) end,
      capabilities: %{
        "system" => FermixCore.Computers.Capabilities.System,
        "wait" => Wait,
        "touch" => Touch,
        "watch" => Watch,
        "probing" => Probing,
        "stubborn" => Stubborn
      },
      clock: fn -> Agent.get(clock, & &1) end,
      relay: :no_relay,
      send: fn _relay, event, payload ->
        send(test, {:sent, event, payload})
        :ok
      end,
      timer: fn message, delay ->
        send(test, {:timer, message, delay})
        make_ref()
      end,
      link_epoch: fn -> Agent.get(epoch, & &1) end
    ]

    sup = start_supervised!({Invoke, opts})

    %{
      home: home,
      sup: sup,
      admission: Invoke.admission(name),
      switches: switches,
      clock: clock,
      epoch: epoch,
      dir: Journal.dir(home)
    }
  end

  defp open(ctx, id, capability, op, args, fields \\ %{}) do
    header =
      Map.merge(
        %{
          "id" => id,
          "capability" => capability,
          "op" => op,
          "deadline_ms" => 30_000,
          "epoch" => 3,
          "origin" => "chat",
          "turn" => %{"session_id" => "main-7", "tool_call_id" => "call-#{id}"}
        },
        fields
      )

    Invoke.handle(ctx.admission, "invoke_open", header, Jason.encode!(args))
  end

  defp answer(id) do
    assert_receive {:sent, %{"t" => "invoke_result", "id" => ^id} = event, payload}
    {event, payload}
  end

  defp running(name) do
    assert_receive {:running, ^name, pid, part}
    {pid, part}
  end

  defp finish(pid, result), do: send(pid, {:finish, result})

  defp journal(ctx, id) do
    {:ok, entry} = Journal.lookup(ctx.dir, id)
    entry
  end

  describe "admitted and run" do
    test "an echo runs, is journaled before and after, and is answered", ctx do
      TelemetryCapture.attach(
        [
          [:fermix, :computer_invocation, :start],
          [:fermix, :computer_invocation, :complete]
        ],
        session_id: "inv_inv-echo"
      )

      open(ctx, "inv-echo", "system", "echo", %{"text" => "hello"})

      {event, payload} = answer("inv-echo")
      assert %{"status" => "ok", "receipt" => %{"target" => "echo"}} = event
      assert %{"text" => "hello", "engine_version" => _version} = Jason.decode!(payload)

      assert %{status: "ok", capability: "system", op: "echo", origin: "chat"} =
               journal(ctx, "inv-echo")

      assert_receive {:telemetry, [:fermix, :computer_invocation, :start], _m, start}
      assert start.parent_session == "main-7"
      assert start.capability == "system"
      assert_receive {:telemetry, [:fermix, :computer_invocation, :complete], m, done}
      assert done.status == :ok
      assert m.result_bytes == byte_size(payload)
      refute Map.has_key?(done, :text)
    end

    test "an effect runs once and answers what it did", ctx do
      open(ctx, "inv-touch", "touch", "touch", %{"name" => "plan.txt"})

      {event, payload} = answer("inv-touch")
      assert event["status"] == "ok"
      assert Jason.decode!(payload) == %{"touched" => "plan.txt"}
      assert File.read!(Path.join(ctx.home, "plan.txt")) == "touched"
      assert journal(ctx, "inv-touch").target == "touch plan.txt"
    end

    test "a run's file goes after its answer, a frame at a time, each naming its size", ctx do
      open(ctx, "inv-pic", "wait", "wait", %{"name" => "pic"})
      {pid, nil} = running("pic")
      bytes = :binary.copy("p", 70_000)
      finish(pid, {:ok, %{"kind" => "picture"}, bytes})

      {event, _payload} = answer("inv-pic")
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

      assert event["part"] == %{
               "size_bytes" => 70_000,
               "sha256" => sha,
               "mime" => "application/octet-stream"
             }

      assert_receive {:sent, %{"t" => "invoke_part", "index" => 0, "last" => false} = first, a}
      assert_receive {:sent, %{"t" => "invoke_part", "index" => 1, "last" => true} = second, b}
      assert first["size_bytes"] == 70_000 and second["size_bytes"] == 70_000
      assert a <> b == bytes
    end

    # A tool that ran and failed is failed, never ok: its short message on the
    # answer, its whole result and part beside it, `failed` in the journal and
    # an error bookend.
    test "a run that failed with its result is answered failed, the result and part whole",
         ctx do
      TelemetryCapture.attach([[:fermix, :computer_invocation, :error]],
        session_id: "inv_inv-fail"
      )

      open(ctx, "inv-fail", "wait", "wait", %{"name" => "fail"})
      {pid, nil} = running("fail")
      whole = "Command failed (exit code 3):\n" <> :binary.copy("x", 70_000)
      result = %{"success" => false, "output" => nil, "error" => nil, "text_part" => "error"}
      finish(pid, {:failed, "Command failed (exit code 3):", result, whole})

      {event, payload} = answer("inv-fail")
      assert event["status"] == "failed"
      assert event["message"] == "Command failed (exit code 3):"
      assert event["part"]["size_bytes"] == byte_size(whole)
      assert Jason.decode!(payload) == result
      assert_receive {:sent, %{"t" => "invoke_part", "index" => 0}, a}
      assert_receive {:sent, %{"t" => "invoke_part", "index" => 1, "last" => true}, b}
      assert a <> b == whole
      assert journal(ctx, "inv-fail").status == "failed"
      assert_receive {:telemetry, [:fermix, :computer_invocation, :error], _m, %{status: :failed}}
    end

    test "a failed run's result past its bounds keeps the message alone", ctx do
      open(ctx, "inv-big-fail", "wait", "wait", %{"name" => "big-fail"})
      {pid, nil} = running("big-fail")
      result = %{"success" => false, "output" => nil, "error" => :binary.copy("y", 2_000)}
      finish(pid, {:failed, "It failed.", result, nil})

      {event, payload} = answer("inv-big-fail")
      assert event["status"] == "failed"
      assert event["message"] == "It failed."
      assert payload == "{}"
      refute Map.has_key?(event, "part")
    end
  end

  describe "refused before anything runs" do
    test "a request from an older copy of the home never acts", ctx do
      Agent.update(ctx.epoch, fn _ -> {:ok, 5} end)
      open(ctx, "inv-old", "touch", "touch", %{"name" => "old.txt"}, %{"epoch" => 4})

      {event, _payload} = answer("inv-old")
      assert %{"status" => "refused", "refusal" => "stale_epoch"} = event
      refute File.exists?(Path.join(ctx.home, "old.txt"))

      assert %{status: "refused", refusal: "stale_epoch", capability: "touch"} =
               journal(ctx, "inv-old")
    end

    test "the master switch off refuses everything, and an offer's switch its own", ctx do
      Agent.update(ctx.switches, fn _ -> Switches.only([:files], enabled: false) end)
      open(ctx, "inv-m", "system", "echo", %{"text" => "x"})
      assert {%{"status" => "refused", "refusal" => "off"}, _payload} = answer("inv-m")

      Agent.update(ctx.switches, fn _ -> Switches.only([:browser]) end)
      open(ctx, "inv-o", "touch", "touch", %{"name" => "o.txt"})
      assert {%{"status" => "refused", "refusal" => "off"} = event, _payload} = answer("inv-o")
      assert event["message"] =~ "Switched off on this"
      refute File.exists?(Path.join(ctx.home, "o.txt"))

      Agent.update(ctx.switches, fn _ -> Switches.only([:files], reviewed: false) end)
      open(ctx, "inv-r", "touch", "touch", %{"name" => "r.txt"})
      assert {%{"refusal" => "off", "message" => "Waiting for you" <> _}, _p} = answer("inv-r")
    end

    test "what this computer cannot do is unavailable, and args it refuses fail", ctx do
      open(ctx, "inv-u", "browser", "open", %{})
      assert {%{"status" => "refused", "refusal" => "unavailable"}, _p} = answer("inv-u")

      open(ctx, "inv-op", "system", "reboot", %{})
      assert {%{"status" => "refused", "refusal" => "unavailable"}, _p} = answer("inv-op")

      open(ctx, "inv-a", "touch", "touch", %{"where" => "x"})
      assert {%{"status" => "failed", "message" => "Touch needs a name."}, _p} = answer("inv-a")

      open(ctx, "inv-d", "system", "echo", %{"text" => "x"}, %{"deadline_ms" => 0})
      assert {%{"status" => "refused", "refusal" => "unavailable"}, _p} = answer("inv-d")

      open(ctx, "inv-t", "system", "echo", %{"text" => "x"}, %{"turn" => nil})
      assert {%{"status" => "refused", "refusal" => "unavailable"}, _p} = answer("inv-t")
    end

    test "the capability's own rules apply to the origin the server names", ctx do
      open(ctx, "inv-s", "touch", "touch", %{"name" => "s.txt"}, %{"origin" => "scheduled"})
      assert {%{"status" => "refused", "refusal" => "not_attended"}, _p} = answer("inv-s")
      refute File.exists?(Path.join(ctx.home, "s.txt"))
    end
  end

  describe "bounds" do
    test "eight run, thirty-two wait in order, and the next is busy", ctx do
      for n <- 1..40, do: open(ctx, "inv-#{n}", "wait", "wait", %{"name" => "w#{n}"})
      open(ctx, "inv-41", "wait", "wait", %{"name" => "w41"})

      assert {%{"status" => "refused", "refusal" => "busy"}, _p} = answer("inv-41")
      runs = for n <- 1..8, do: running("w#{n}")
      refute_received {:running, "w9", _pid, _part}

      {first, nil} = hd(runs)
      finish(first, {:ok, %{}, nil})
      assert {%{"status" => "ok"}, _p} = answer("inv-1")
      assert {_ninth, nil} = running("w9")
      refute_received {:running, "w10", _pid, _part}
    end
  end

  describe "deadlines, cancels and the master switch" do
    test "past its deadline a run is stopped and answered timed_out", ctx do
      open(ctx, "inv-slow", "wait", "wait", %{"name" => "slow"}, %{"deadline_ms" => 5_000})
      assert_receive {:timer, {:deadline, "inv-slow"} = deadline, 5_000}
      {pid, nil} = running("slow")
      ref = Process.monitor(pid)

      send(ctx.admission, deadline)

      assert {%{"status" => "timed_out"}, _p} = answer("inv-slow")
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      assert journal(ctx, "inv-slow").status == "timed_out"
    end

    test "a cancel is answered exactly once: cancelled, or what came first", ctx do
      open(ctx, "inv-c", "wait", "wait", %{"name" => "c"})
      {_pid, nil} = running("c")

      Invoke.handle(ctx.admission, "invoke_cancel", %{"id" => "inv-c"}, <<>>)
      assert {%{"status" => "cancelled"}, _p} = answer("inv-c")

      Invoke.handle(ctx.admission, "invoke_cancel", %{"id" => "inv-c"}, <<>>)
      assert {%{"status" => "cancelled"}, _p} = answer("inv-c")
      refute_received {:sent, %{"id" => "inv-c"}, _payload}

      open(ctx, "inv-done", "system", "echo", %{"text" => "x"})
      assert {%{"status" => "ok"}, _p} = answer("inv-done")
      Invoke.handle(ctx.admission, "invoke_cancel", %{"id" => "inv-done"}, <<>>)
      assert {%{"status" => "ok"}, _p} = answer("inv-done")
    end

    test "the master switch off ends what runs and waits as stopped here", ctx do
      open(ctx, "inv-run", "wait", "wait", %{"name" => "run"})
      {pid, nil} = running("run")
      ref = Process.monitor(pid)

      Agent.update(ctx.switches, fn _ -> Switches.only([:files], enabled: false) end)
      :ok = Admission.switches_changed(ctx.admission)

      assert {%{"status" => "refused", "refusal" => "stopped_here"}, _p} = answer("inv-run")
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

      open(ctx, "inv-after", "system", "echo", %{"text" => "x"})
      assert {%{"status" => "refused", "refusal" => "off"}, _p} = answer("inv-after")
    end

    # Nothing starts while the switch is off, though Admission has not heard
    # yet: the switches are read again the moment a waiting request would start.
    test "a request that waited for a slot never starts once the switch went off", ctx do
      for n <- 1..9, do: open(ctx, "inv-#{n}", "wait", "wait", %{"name" => "q#{n}"})
      [{first, nil} | _runs] = for n <- 1..8, do: running("q#{n}")
      # Admission has taken all nine before the switch goes off: the ninth waits.
      _state = :sys.get_state(ctx.admission)

      Agent.update(ctx.switches, fn _ -> Switches.only([:files], enabled: false) end)
      finish(first, {:ok, %{}, nil})

      assert {%{"status" => "ok"}, _p} = answer("inv-1")
      assert {%{"status" => "refused", "refusal" => "off"}, _p} = answer("inv-9")
      refute_received {:running, "q9", _pid, _part}
      assert %{status: "refused", refusal: "off"} = journal(ctx, "inv-9")
    end

    test "a request that waited for its upload never starts once the switch went off", ctx do
      sha = :sha256 |> :crypto.hash("abc") |> Base.encode16(case: :lower)
      part = %{"size_bytes" => 3, "sha256" => sha, "mime" => "text/plain"}
      open(ctx, "inv-up-off", "wait", "wait", %{"name" => "upoff"}, %{"part" => part})
      # Admission has taken it, and it waits for its part, before the switch goes off.
      _state = :sys.get_state(ctx.admission)

      Agent.update(ctx.switches, fn _ -> Switches.only([:browser]) end)
      frame = %{"id" => "inv-up-off", "size_bytes" => 3, "index" => 0, "last" => true}
      Invoke.handle(ctx.admission, "invoke_part", frame, "abc")

      assert {%{"status" => "refused", "refusal" => "off"}, _p} = answer("inv-up-off")
      refute_received {:running, "upoff", _pid, _part}
    end

    test "the master switch off ends what waits too", ctx do
      for n <- 1..9, do: open(ctx, "inv-#{n}", "wait", "wait", %{"name" => "s#{n}"})
      for n <- 1..8, do: running("s#{n}")
      # Admission has taken all nine before the switch goes off: the ninth waits.
      _state = :sys.get_state(ctx.admission)

      Agent.update(ctx.switches, fn _ -> Switches.only([:files], enabled: false) end)
      :ok = Admission.switches_changed(ctx.admission)

      for n <- 1..9 do
        id = "inv-#{n}"
        assert {%{"status" => "refused", "refusal" => "stopped_here"}, _p} = answer(id)
      end

      refute_received {:running, "s9", _pid, _part}
    end

    # A capability's cancel that never answers in time is the run's to bear:
    # Admission answers at once and goes on, and the run still ends.
    test "a cancel that times out is answered, and Admission goes on", ctx do
      open(ctx, "inv-stuck", "stubborn", "hold", %{"name" => "stuck"})
      {pid, nil} = running("stuck")
      ref = Process.monitor(pid)
      admission = Process.whereis(ctx.admission)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Invoke.handle(ctx.admission, "invoke_cancel", %{"id" => "inv-stuck"}, <<>>)
          assert {%{"status" => "cancelled"}, _p} = answer("inv-stuck")
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
        end)

      assert log =~ "did not let go"
      assert Process.whereis(ctx.admission) == admission
      open(ctx, "inv-next", "system", "echo", %{"text" => "x"})
      assert {%{"status" => "ok"}, _p} = answer("inv-next")
    end
  end

  # A capability's own rules may read the owner's folders, which can hang on
  # a network mount that stopped answering: they run beside Admission, so it
  # admits, cancels and answers everything else meanwhile.
  describe "the capability's own rules" do
    test "run beside Admission, which answers other requests meanwhile", ctx do
      open(ctx, "inv-probe", "probing", "probe", %{"name" => "slow mount"})
      assert_receive {:admitting, "slow mount", admitting}

      open(ctx, "inv-echo", "system", "echo", %{"text" => "x"})
      assert {%{"status" => "ok"}, _p} = answer("inv-echo")

      send(admitting, {:admit, :ok})
      assert {%{"status" => "ok"}, ~s({"probed":"slow mount"})} = answer("inv-probe")
    end

    test "still refuse, and the refusal is journaled", ctx do
      open(ctx, "inv-no", "probing", "probe", %{"name" => "outside"})
      assert_receive {:admitting, "outside", admitting}
      send(admitting, {:admit, {:refused, :outside_sandbox, "Not inside the sandbox."}})

      assert {%{"status" => "refused", "refusal" => "outside_sandbox"}, _p} = answer("inv-no")
      assert %{status: "refused", refusal: "outside_sandbox"} = journal(ctx, "inv-no")
    end

    test "a request whose rules are still deciding is cancelled at once", ctx do
      open(ctx, "inv-held", "probing", "probe", %{"name" => "held"})
      assert_receive {:admitting, "held", admitting}
      ref = Process.monitor(admitting)

      Invoke.handle(ctx.admission, "invoke_cancel", %{"id" => "inv-held"}, <<>>)

      assert {%{"status" => "cancelled"}, _p} = answer("inv-held")
      assert_receive {:DOWN, ^ref, :process, ^admitting, _reason}
    end
  end

  # One rule, the one a request is admitted by: the capability's offer
  # against this computer's switches.
  describe "an offer's own switch off, the master on" do
    test "refuses that capability's work that runs and waits as off, and nothing else", ctx do
      Agent.update(ctx.switches, fn _ -> Switches.only([:files, :imessage]) end)
      open(ctx, "inv-watch", "watch", "watch", %{"name" => "watch"}, %{"deadline_ms" => 0})
      {watch, nil} = running("watch")
      for n <- 1..7, do: open(ctx, "inv-#{n}", "wait", "wait", %{"name" => "f#{n}"})
      for n <- 1..7, do: running("f#{n}")
      open(ctx, "inv-8", "wait", "wait", %{"name" => "f8"})
      open(ctx, "inv-later", "watch", "watch", %{"name" => "later"}, %{"deadline_ms" => 0})
      # Admission has taken both before the switch goes off: each waits for a slot.
      _state = :sys.get_state(ctx.admission)

      Agent.update(ctx.switches, fn _ -> Switches.only([:imessage]) end)
      :ok = Admission.switches_changed(ctx.admission)

      for n <- 1..8 do
        {event, _payload} = answer("inv-#{n}")
        assert %{"status" => "refused", "refusal" => "off"} = event
        assert event["message"] =~ "Switched off on this"
        assert %{status: "refused", refusal: "off"} = journal(ctx, "inv-#{n}")
      end

      # The other offer's work goes on, and its request that waited takes a slot.
      assert {_later, nil} = running("later")
      refute_received {:running, "f8", _pid, _part}
      refute_received {:sent, %{"id" => "inv-watch"}, _payload}
      finish(watch, {:ok, %{"seen" => 1}, nil})
      assert {%{"status" => "ok"}, ~s({"seen":1})} = answer("inv-watch")

      open(ctx, "inv-after", "wait", "wait", %{"name" => "after"})
      assert {%{"status" => "refused", "refusal" => "off"}, _p} = answer("inv-after")
    end

    # A switch's own listener (the browser's held turns, the screen's seat) can
    # end a run before Admission hears: its answer is still the switch's.
    test "a run that ends under its switch, off before Admission heard, is answered off", ctx do
      open(ctx, "inv-x", "wait", "wait", %{"name" => "x"})
      {pid, nil} = running("x")

      Agent.update(ctx.switches, fn _ -> Switches.only([]) end)
      Process.exit(pid, :kill)

      {event, _payload} = answer("inv-x")
      assert %{"status" => "refused", "refusal" => "off"} = event
      assert event["message"] =~ "Switched off on this"
      assert %{status: "refused", refusal: "off"} = journal(ctx, "inv-x")

      Agent.update(ctx.switches, fn _ -> Switches.only([:files]) end)
      open(ctx, "inv-y", "wait", "wait", %{"name" => "y"})
      {other, nil} = running("y")

      Agent.update(ctx.switches, fn _ -> Switches.only([:files], enabled: false) end)
      Process.exit(other, :kill)

      assert {%{"status" => "refused", "refusal" => "stopped_here"}, _p} = answer("inv-y")
    end
  end

  describe "after a lost answer" do
    test "a held answer is sent again, then the receipt alone, then unknown", ctx do
      open(ctx, "inv-h", "system", "echo", %{"text" => "kept"})
      {first, payload} = answer("inv-h")

      Invoke.handle(ctx.admission, "invoke_status", %{"id" => "inv-h"}, <<>>)
      assert answer("inv-h") == {first, payload}

      Agent.update(ctx.clock, &DateTime.add(&1, 11, :minute))
      Invoke.handle(ctx.admission, "invoke_status", %{"id" => "inv-h"}, <<>>)
      {receipt, receipt_payload} = answer("inv-h")
      assert receipt_payload == ~s({"receipt_only":true})
      assert %{"status" => "ok", "receipt" => %{"target" => "echo"}} = receipt

      Invoke.handle(ctx.admission, "invoke_status", %{"id" => "inv-never"}, <<>>)
      {unknown, "{}"} = answer("inv-never")
      assert unknown["status"] == "unknown"
      refute Map.has_key?(unknown, "receipt")
    end

    test "one still running is answered when it ends, not before", ctx do
      open(ctx, "inv-w", "wait", "wait", %{"name" => "w"})
      {pid, nil} = running("w")

      Invoke.handle(ctx.admission, "invoke_status", %{"id" => "inv-w"}, <<>>)
      finish(pid, {:ok, %{"done" => true}, nil})

      assert {%{"status" => "ok"}, ~s({"done":true})} = answer("inv-w")
      refute_received {:sent, %{"id" => "inv-w"}, _payload}
    end

    test "a request asked again is never run twice", ctx do
      open(ctx, "inv-twice", "touch", "touch", %{"name" => "once.txt"})
      assert {%{"status" => "ok"}, _p} = answer("inv-twice")
      # Moved aside: a second run would write it again.
      File.rename!(Path.join(ctx.home, "once.txt"), Path.join(ctx.home, "first.txt"))

      ExUnit.CaptureLog.capture_log(fn ->
        open(ctx, "inv-twice", "touch", "touch", %{"name" => "once.txt"})
        assert {%{"status" => "ok"}, _p} = answer("inv-twice")
      end)

      refute File.exists?(Path.join(ctx.home, "once.txt"))
    end

    test "a crash while it ran leaves it journaled unknown, interrupted", ctx do
      open(ctx, "inv-x", "wait", "wait", %{"name" => "x"})
      {_pid, nil} = running("x")
      assert %{status: nil} = journal(ctx, "inv-x")

      admission = Process.whereis(ctx.admission)
      ref = Process.monitor(admission)

      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(admission, :kill)
        assert_receive {:DOWN, ^ref, :process, ^admission, :killed}
        await_restarted(ctx.admission, admission)
      end)

      assert %{status: "unknown"} = journal(ctx, "inv-x")

      # The restart tells the server itself, with the journal's receipt, so a
      # caller with no session that ends is not left waiting; a status ask
      # after it is answered the same.
      {told, ~s({"receipt_only":true})} = answer("inv-x")
      assert %{"status" => "unknown", "message" => "Fermix on this computer stopped" <> _} = told
      assert %{"receipt" => %{"target" => "wait x"}} = told

      Invoke.handle(ctx.admission, "invoke_status", %{"id" => "inv-x"}, <<>>)
      {event, ~s({"receipt_only":true})} = answer("inv-x")
      assert event == told
    end

    # What only waited never started, so the journal holds nothing of it: the
    # restart answers it too, at once, as never run, a long-lived one and one
    # that waited for its upload included, while what ran stays not known.
    test "a crash while requests waited answers each, never run", ctx do
      Agent.update(ctx.switches, fn _ -> Switches.only([:files, :imessage]) end)
      for n <- 1..8, do: open(ctx, "inv-#{n}", "wait", "wait", %{"name" => "r#{n}"})
      for n <- 1..8, do: running("r#{n}")
      open(ctx, "inv-watch", "watch", "watch", %{"name" => "watch"}, %{"deadline_ms" => 0})
      sha = :sha256 |> :crypto.hash("abc") |> Base.encode16(case: :lower)
      part = %{"size_bytes" => 3, "sha256" => sha, "mime" => "text/plain"}
      open(ctx, "inv-up", "wait", "wait", %{"name" => "up"}, %{"part" => part})
      # Admission has taken both before it stops: one waits for a slot, one for its part.
      _state = :sys.get_state(ctx.admission)

      admission = Process.whereis(ctx.admission)
      ref = Process.monitor(admission)

      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(admission, :kill)
        assert_receive {:DOWN, ^ref, :process, ^admission, :killed}
        await_restarted(ctx.admission, admission)
      end)

      for id <- ["inv-watch", "inv-up"] do
        {event, "{}"} = answer(id)
        assert %{"status" => "refused", "refusal" => "unavailable", "message" => message} = event

        assert message ==
                 "Fermix on this computer restarted before it ran this, so it did not run."

        assert %{status: "refused", refusal: "unavailable", capability: _named} =
                 journal(ctx, id)
      end

      for n <- 1..8 do
        assert {%{"status" => "unknown"}, ~s({"receipt_only":true})} = answer("inv-#{n}")
      end

      refute_received {:running, "watch", _pid, _part}
      frame = %{"id" => "inv-up", "size_bytes" => 3, "index" => 0, "last" => true}
      Invoke.handle(ctx.admission, "invoke_part", frame, "abc")
      Invoke.handle(ctx.admission, "invoke_status", %{"id" => "inv-watch"}, <<>>)
      assert {%{"status" => "refused", "refusal" => "unavailable"}, "{}"} = answer("inv-watch")
      refute_received {:running, "up", _pid, _part}
    end

    # INVOKE-2: a request on its way while Admission was down never reached
    # it, so no restart answers it: the restart tells the server, which asks
    # about everything it still waits on, and hears there is no record.
    test "each start tells the server, which asks again about what it waits on", ctx do
      assert_receive {:sent, %{"t" => "invoke_restarted"}, ""}
      admission = Process.whereis(ctx.admission)
      ref = Process.monitor(admission)

      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(admission, :kill)
        assert_receive {:DOWN, ^ref, :process, ^admission, :killed}
        await_restarted(ctx.admission, admission)
      end)

      assert_receive {:sent, %{"t" => "invoke_restarted"} = told, ""}
      assert Map.keys(told) == ["t"]

      Invoke.handle(ctx.admission, "invoke_status", %{"id" => "inv-lost"}, <<>>)
      assert {%{"status" => "unknown"}, "{}"} = answer("inv-lost")
    end

    # What waited when the request handler's own supervisor restarted went
    # with its table: the new Admission still tells the server, whose ask is
    # answered unknown, so no caller is left waiting.
    test "a restart of the whole request handler is told too", ctx do
      assert_receive {:sent, %{"t" => "invoke_restarted"}, ""}
      Agent.update(ctx.switches, fn _ -> Switches.only([:files, :imessage]) end)
      for n <- 1..8, do: open(ctx, "inv-#{n}", "wait", "wait", %{"name" => "h#{n}"})
      for n <- 1..8, do: running("h#{n}")
      open(ctx, "inv-watch", "watch", "watch", %{"name" => "watch"}, %{"deadline_ms" => 0})
      # Admission has taken the watch, and it waits for a slot.
      _state = :sys.get_state(ctx.admission)
      admission = Process.whereis(ctx.admission)
      sup_ref = Process.monitor(ctx.sup)

      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(ctx.sup, :kill)
        assert_receive {:DOWN, ^sup_ref, :process, _sup, :killed}
        await_restarted(ctx.admission, admission)
      end)

      assert_receive {:sent, %{"t" => "invoke_restarted"}, ""}
      refute_received {:sent, %{"id" => "inv-watch"}, _payload}

      Invoke.handle(ctx.admission, "invoke_status", %{"id" => "inv-watch"}, <<>>)
      assert {%{"status" => "unknown"}, "{}"} = answer("inv-watch")
    end
  end

  describe "an upload" do
    test "a request waits for its part, which reaches the run whole", ctx do
      bytes = :binary.copy("u", 70_000)
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      part = %{"size_bytes" => 70_000, "sha256" => sha, "mime" => "text/plain"}
      open(ctx, "inv-up", "wait", "wait", %{"name" => "up"}, %{"part" => part})
      refute_received {:running, "up", _pid, _part}

      <<a::binary-size(61_440), b::binary>> = bytes
      frame = %{"id" => "inv-up", "size_bytes" => 70_000}

      Invoke.handle(
        ctx.admission,
        "invoke_part",
        Map.merge(frame, %{"index" => 0, "last" => false}),
        a
      )

      Invoke.handle(
        ctx.admission,
        "invoke_part",
        Map.merge(frame, %{"index" => 1, "last" => true}),
        b
      )

      assert {_pid, ^bytes} = running("up")
    end

    test "a part with a gap fails the request, and the session goes on", ctx do
      sha = :sha256 |> :crypto.hash("abcdef") |> Base.encode16(case: :lower)
      part = %{"size_bytes" => 6, "sha256" => sha, "mime" => "text/plain"}
      open(ctx, "inv-gap", "wait", "wait", %{"name" => "gap"}, %{"part" => part})

      frame = %{"id" => "inv-gap", "size_bytes" => 6, "index" => 1, "last" => true}
      Invoke.handle(ctx.admission, "invoke_part", frame, "def")

      assert {%{"status" => "failed", "message" => "The upload did not arrive whole."}, _p} =
               answer("inv-gap")

      refute_received {:running, "gap", _pid, _part}
      assert Process.alive?(Process.whereis(ctx.admission))
    end
  end

  defp await_restarted(name, old, attempts \\ 1_000) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old ->
        _state = :sys.get_state(pid)
        :ok

      _gone when attempts == 0 ->
        flunk("the invocations never started again")

      _gone ->
        # sleep: polls a supervisor's restart, which announces nothing
        Process.sleep(10)
        await_restarted(name, old, attempts - 1)
    end
  end
end
