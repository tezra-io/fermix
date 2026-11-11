defmodule FermixCore.Computers.InvocationTest do
  # M97 §6.1, §6.3: the server's side of an invocation, with the link stood
  # in for: what is refused before anything is sent, what is sent, and how
  # a lost answer ends. The computer's side and the real link are in
  # FermixChannels' two-engine tests.
  use ExUnit.Case, async: true

  alias FermixCore.Computers
  alias FermixCore.Computers.Calls
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry
  alias FermixTestSupport.TelemetryCapture

  @device "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @files_on %{id: "files", state: :on, sentence: nil, detail: nil}

  # A link that tells the test what it was asked, and answers `:open` as told.
  defmodule Link do
    @moduledoc false
    @behaviour FermixCore.Computers.Transport

    @impl true
    def open(device_id, header, payload, part, opts) do
      send(Keyword.fetch!(opts, :test), {:opened, device_id, header, payload, part})
      Keyword.get(opts, :open, :ok)
    end

    @impl true
    def cancel(device_id, %{id: id} = about, opts) do
      send(Keyword.fetch!(opts, :test), {:cancelled, device_id, id, about})
      :ok
    end

    @impl true
    def status(device_id, %{id: id} = about, opts) do
      send(Keyword.fetch!(opts, :test), {:asked, device_id, id, about})
      :ok
    end
  end

  defmodule Look do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :files
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["look"]
    @impl true
    def effect?(_op), do: false
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate("look", %{"path" => path}) when is_binary(path), do: :ok
    def validate("look", _args), do: {:error, "Look needs a path."}
    @impl true
    def bounds(_op), do: %{result_bytes: 4_096, part_bytes: 1_024}
    @impl true
    def admit(_op, _args, _context), do: :ok
    @impl true
    def run(_op, _args, _part, _context), do: {:ok, %{}, nil}
    @impl true
    def target("look", %{"path" => path}), do: path
  end

  defmodule Touch do
    @moduledoc false
    @behaviour FermixCore.Computers.Capability

    @impl true
    def id, do: :files
    @impl true
    def offer, do: :files
    @impl true
    def ops, do: ["touch"]
    @impl true
    def effect?(_op), do: true
    @impl true
    def long_lived?(_op), do: false
    @impl true
    def validate(_op, _args), do: :ok
    @impl true
    def bounds(_op), do: %{result_bytes: 4_096, part_bytes: 0}
    @impl true
    def admit(_op, _args, _context), do: :ok
    @impl true
    def run(_op, _args, _part, _context), do: {:ok, %{}, nil}
    @impl true
    def target("touch", %{"path" => path}), do: "touch #{path}"
  end

  setup do
    calls = :"invocation_calls_#{System.unique_integer([:positive])}"
    start_supervised!({Calls, name: calls})
    %{calls: calls}
  end

  defp computer(fields \\ []) do
    struct!(
      %Computer{device_id: @device, name: "studio Mac", connected: true, offers: [@files_on]},
      fields
    )
  end

  defp opts(ctx, more \\ []) do
    [
      calls: ctx.calls,
      transport: {Link, [test: self()] ++ Keyword.get(more, :link, [])},
      epoch: 4
    ]
    |> Keyword.merge(Keyword.delete(more, :link))
  end

  defp turn,
    do: %{session_id: "main-21", computer_use_origin: :interactive, source_trust: :operator}

  # The caller blocks, so it runs beside the test, which plays the computer.
  defp call_async(ctx, module, op, args, more \\ []) do
    computer = Keyword.get(more, :computer, computer())
    opts = opts(ctx, Keyword.delete(more, :computer))
    Task.async(fn -> Computers.call(computer, module, op, args, turn(), opts) end)
  end

  defp answer(ctx, id, fields, payload \\ "{}"),
    do:
      Calls.deliver(
        ctx.calls,
        @device,
        id,
        {Map.merge(%{"id" => id, "duration_ms" => 3}, fields), payload}
      )

  describe "before anything is sent" do
    test "a computer that is away is refused at once, in its own words", ctx do
      task = call_async(ctx, Look, "look", %{"path" => "a"}, computer: computer(connected: false))

      assert {:error, %Outcome{status: :refused, refusal: :unavailable} = outcome} =
               Task.await(task)

      assert Outcome.sentence(outcome, "studio Mac") ==
               "studio Mac is asleep or offline, so Fermix cannot reach it now."

      refute_received {:opened, _device, _header, _payload, _part}
    end

    test "an offer that is off or unavailable is refused in that offer's words", ctx do
      off = %{@files_on | state: :off, sentence: "Switched off on this Mac."}
      task = call_async(ctx, Look, "look", %{"path" => "a"}, computer: computer(offers: [off]))
      assert {:error, %Outcome{status: :refused, refusal: :off} = outcome} = Task.await(task)
      assert outcome.capability == "files"

      assert Outcome.sentence(outcome, "studio Mac") ==
               "studio Mac has files switched off. Only someone at studio Mac can switch it on."

      gone = %{@files_on | state: :unavailable, sentence: "Files are not here."}
      task = call_async(ctx, Look, "look", %{"path" => "a"}, computer: computer(offers: [gone]))

      assert {:error, %Outcome{refusal: :unavailable, message: "Files are not here."}} =
               Task.await(task)

      task = call_async(ctx, Look, "look", %{"path" => "a"}, computer: computer(offers: []))
      assert {:error, %Outcome{refusal: :unavailable}} = Task.await(task)
      refute_received {:opened, _device, _header, _payload, _part}
    end

    test "args the capability refuses fail with its sentence, and nothing is sent", ctx do
      task = call_async(ctx, Look, "look", %{"where" => "a"})
      assert {:error, %Outcome{status: :failed, message: "Look needs a path."}} = Task.await(task)
      refute_received {:opened, _device, _header, _payload, _part}
    end
  end

  describe "sent and answered" do
    test "the request names its turn, its epoch and its deadline, and the answer comes back",
         ctx do
      task = call_async(ctx, Look, "look", %{"path" => "drafts/plan.txt"}, deadline_ms: 20_000)

      assert_receive {:opened, @device, header, payload, nil}
      assert %{"id" => "inv-" <> _rest = id} = header
      assert byte_size(id) == 30

      assert Map.delete(header, "id") == %{
               "capability" => "files",
               "op" => "look",
               "deadline_ms" => 20_000,
               "epoch" => 4,
               "origin" => "chat",
               "turn" => %{"session_id" => "main-21", "tool_call_id" => id}
             }

      assert Jason.decode!(payload) == %{"path" => "drafts/plan.txt"}
      assert Calls.outstanding(ctx.calls, @device) == [id]

      answer(ctx, id, %{"status" => "ok"}, ~s({"size":12}))

      assert {:ok, %Outcome{status: :ok, result: %{"size" => 12}} = outcome} = Task.await(task)
      assert outcome.invocation == id
      assert outcome.computer == @device
      assert outcome.target == "drafts/plan.txt"
      assert Calls.outstanding(ctx.calls, @device) == []
    end

    test "a part announced by the answer completes it once it arrives, whichever comes first",
         ctx do
      bytes = "a picture of the plan"
      sha = :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
      part = %{"size_bytes" => byte_size(bytes), "sha256" => sha, "mime" => "image/png"}
      parent = self()
      progress = fn seen -> send(parent, {:progress, seen}) end

      task = call_async(ctx, Look, "look", %{"path" => "a"}, on_part: progress)
      assert_receive {:opened, @device, %{"id" => id}, _payload, nil}

      :ok = Calls.part(ctx.calls, @device, id, {:progress, 4, byte_size(bytes)})
      :ok = Calls.part(ctx.calls, @device, id, {:done, bytes})
      answer(ctx, id, %{"status" => "ok", "part" => part})

      assert {:ok, %Outcome{part_bytes: ^bytes}} = Task.await(task)
      assert_received {:progress, %{received_bytes: 4, size_bytes: 21}}
    end

    test "a read whose file does not match its announcement fails", ctx do
      part = %{"size_bytes" => 3, "sha256" => String.duplicate("0", 64), "mime" => "image/png"}
      task = call_async(ctx, Look, "look", %{"path" => "a"})
      assert_receive {:opened, @device, %{"id" => id}, _payload, nil}

      answer(ctx, id, %{"status" => "ok", "part" => part})
      :ok = Calls.part(ctx.calls, @device, id, {:done, "abc"})

      assert {:error,
              %Outcome{status: :failed, message: "The answer's file did not arrive whole."}} =
               Task.await(task)
    end

    # C3: an effect ran, so losing its file on the way never makes it a
    # failure the model would run again: it stays done, and says its output
    # was lost (`part_lost`).
    test "an effect whose file is lost on the way stays done, its output said lost", ctx do
      part = %{"size_bytes" => 3, "sha256" => String.duplicate("0", 64), "mime" => "text/plain"}
      task = call_async(ctx, Touch, "touch", %{"path" => "a"})
      assert_receive {:opened, @device, %{"id" => id}, _payload, nil}

      answer(ctx, id, %{"status" => "ok", "part" => part}, ~s({"success":true}))

      :ok =
        Calls.part(ctx.calls, @device, id, {:error, "The answer's file did not arrive whole."})

      assert {:ok, %Outcome{status: :ok, part_lost: true, part_bytes: nil} = outcome} =
               Task.await(task)

      assert Outcome.sentence(outcome, "studio Mac") ==
               "studio Mac ran it, but its output was lost on the way back, so it is not run " <>
                 "again."
    end

    test "an upload is announced with the request and handed to the link", ctx do
      task = call_async(ctx, Look, "look", %{"path" => "a"}, part: {"notes", "text/plain"})
      assert_receive {:opened, @device, %{"id" => id} = header, _payload, "notes"}

      assert header["part"] == %{
               "size_bytes" => 5,
               "sha256" => :sha256 |> :crypto.hash("notes") |> Base.encode16(case: :lower),
               "mime" => "text/plain"
             }

      answer(ctx, id, %{"status" => "ok"})
      assert {:ok, _outcome} = Task.await(task)
    end

    test "an answer from another computer is dropped", ctx do
      task = call_async(ctx, Look, "look", %{"path" => "a"})
      assert_receive {:opened, @device, %{"id" => id}, _payload, nil}

      ExUnit.CaptureLog.capture_log(fn ->
        fields = %{"id" => id, "status" => "ok", "duration_ms" => 1}
        :ok = Calls.deliver(ctx.calls, "0d3f8a7e-5c21-4b9e-8f60-2a4c6e8b1d37", id, {fields, "{}"})
        assert Calls.outstanding(ctx.calls, @device) == [id]
      end)

      answer(ctx, id, %{"status" => "ok"}, ~s({"from":"studio"}))
      assert {:ok, %Outcome{result: %{"from" => "studio"}}} = Task.await(task)
    end
  end

  describe "a lost answer" do
    test "an effect whose outcome is not known is never sent again", ctx do
      task = call_async(ctx, Touch, "touch", %{"path" => "drafts/plan.txt"})
      assert_receive {:opened, @device, %{"id" => id}, _payload, nil}

      answer(ctx, id, %{"status" => "unknown"})

      assert {:error, %Outcome{status: :unknown} = outcome} = Task.await(task)

      assert Outcome.sentence(outcome, "studio Mac") =~
               "whether touch drafts/plan.txt happened is not known"

      refute_received {:opened, _device, _header, _payload, _part}
    end

    test "an effect with only its receipt left is not sent again either", ctx do
      task = call_async(ctx, Touch, "touch", %{"path" => "a"})
      assert_receive {:opened, @device, %{"id" => id}, _payload, nil}

      receipt = %{"at" => "2031-06-08T12:00:00Z", "target" => "touch a"}
      answer(ctx, id, %{"status" => "ok", "receipt" => receipt}, ~s({"receipt_only":true}))

      assert {:ok, %Outcome{receipt_only: true}} = Task.await(task)
      refute_received {:opened, _device, _header, _payload, _part}
    end

    test "a read whose outcome is not known is asked once more under a new id", ctx do
      task = call_async(ctx, Look, "look", %{"path" => "a"})
      assert_receive {:opened, @device, %{"id" => first}, _payload, nil}
      answer(ctx, first, %{"status" => "unknown"})

      assert_receive {:opened, @device, %{"id" => second}, _payload, nil}
      refute second == first
      answer(ctx, second, %{"status" => "unknown"})

      assert {:error, %Outcome{status: :unknown, invocation: ^second}} = Task.await(task)
      refute_received {:opened, _device, _header, _payload, _part}
    end

    test "with no answer by the deadline an effect is not known and a read timed out", ctx do
      fast = [deadline_ms: 1, grace_ms: 0]

      task = call_async(ctx, Touch, "touch", %{"path" => "a"}, fast)
      assert_receive {:opened, @device, %{"id" => effect}, _payload, nil}
      assert {:error, %Outcome{status: :unknown}} = Task.await(task)
      assert_received {:cancelled, @device, ^effect, %{capability: "files", op: "touch"}}

      task = call_async(ctx, Look, "look", %{"path" => "a"}, fast)
      assert_receive {:opened, @device, %{"id" => read}, _payload, nil}
      assert {:error, %Outcome{status: :timed_out, deadline_ms: 1}} = Task.await(task)
      assert_received {:cancelled, @device, ^read, %{capability: "files", op: "look"}}
      assert Calls.outstanding(ctx.calls, @device) == []
    end

    test "a new session has the caller ask for its own invocation, naming its request", ctx do
      task = call_async(ctx, Look, "look", %{"path" => "a"})
      assert_receive {:opened, @device, %{"id" => id}, _payload, nil}

      assert :ok = Calls.reconnected(ctx.calls, @device)
      assert :ok = Calls.reconnected(ctx.calls, "0d3f8a7e-5c21-4b9e-8f60-2a4c6e8b1d37")
      assert_receive {:asked, @device, ^id, %{id: ^id, capability: "files", op: "look"}}
      refute_received {:asked, _device, _id, _about}

      answer(ctx, id, %{"status" => "ok"})
      assert {:ok, %Outcome{status: :ok}} = Task.await(task)
    end

    test "a session with no computer behind it sends nothing and refuses at once", ctx do
      task =
        call_async(ctx, Touch, "touch", %{"path" => "a"}, link: [open: {:error, :not_connected}])

      assert {:error, %Outcome{status: :refused, refusal: :unavailable}} = Task.await(task)
      assert Calls.outstanding(ctx.calls, @device) == []
    end
  end

  describe "the waiters" do
    test "a caller that ends without its answer has the invocation cancelled", ctx do
      test = self()

      caller =
        spawn(fn ->
          :ok =
            Calls.register(ctx.calls, %{
              id: "inv-abandoned",
              device_id: @device,
              capability: "files",
              op: "touch",
              caller: self(),
              effect?: true,
              started_at: DateTime.utc_now(),
              deadline_at: nil,
              transport: {Link, [test: test]}
            })

          send(test, :registered)
          receive do: (:never -> :ok)
        end)

      assert_receive :registered
      calls = Process.whereis(ctx.calls)
      await_monitored_by(caller, calls)

      assert [%{id: "inv-abandoned", device_id: @device}] = Calls.running_effects(ctx.calls)
      Process.exit(caller, :kill)

      assert_receive {:cancelled, @device, "inv-abandoned", %{capability: "files", op: "touch"}}
      assert Calls.running_effects(ctx.calls) == []
    end
  end

  # The server runs no model tool on a computer yet (stage 1 does); this
  # stands in for one, to hold the rule every tool call obeys: exactly one
  # `[:fermix, :tool, :exec]`, here with the invocation's ids and status,
  # whatever the link did, a read asked twice included.
  test "one tool call on a computer is exactly one tool exec on the server", ctx do
    session = "main-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: session)
    context = %{turn() | session_id: session} |> Map.put(:agent_name, "main")
    opts = opts(ctx)

    task =
      Task.async(fn ->
        started = System.monotonic_time(:millisecond)
        result = Computers.call(computer(), Look, "look", %{"path" => "a"}, context, opts)
        {_ok_or_error, outcome} = result
        duration = System.monotonic_time(:millisecond) - started

        ToolTelemetry.exec("computer_look", context, outcome.status == :ok, duration,
          metadata: Outcome.exec_metadata(outcome)
        )

        result
      end)

    assert_receive {:opened, @device, %{"id" => first}, _payload, nil}
    answer(ctx, first, %{"status" => "unknown"})
    assert_receive {:opened, @device, %{"id" => second}, _payload, nil}
    answer(ctx, second, %{"status" => "ok"})
    assert {:ok, _outcome} = Task.await(task)

    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
    assert metadata.invocation == second
    assert metadata.invoke_status == :ok
    assert metadata.computer == @device
    refute_received {:telemetry, [:fermix, :tool, :exec], _measurements, _metadata}
  end

  defp await_monitored_by(pid, monitor, attempts \\ 10_000) do
    {:monitored_by, watchers} = Process.info(pid, :monitored_by)

    cond do
      monitor in watchers ->
        :ok

      attempts == 0 ->
        flunk("Calls never monitored the caller")

      true ->
        # sleep: polls the caller's monitors, which announce nothing
        Process.sleep(1)
        await_monitored_by(pid, monitor, attempts - 1)
    end
  end
end
