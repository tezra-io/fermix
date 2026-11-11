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
        "touch" => Touch
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

    test "stop_all ends what waits too", ctx do
      for n <- 1..9, do: open(ctx, "inv-#{n}", "wait", "wait", %{"name" => "s#{n}"})
      for n <- 1..8, do: running("s#{n}")

      :ok = Admission.stop_all(ctx.admission, :stopped_here)

      for n <- 1..9 do
        id = "inv-#{n}"
        assert {%{"status" => "refused", "refusal" => "stopped_here"}, _p} = answer(id)
      end

      refute_received {:running, "s9", _pid, _part}
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
