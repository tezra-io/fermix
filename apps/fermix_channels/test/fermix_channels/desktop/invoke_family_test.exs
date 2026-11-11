defmodule FermixChannels.Desktop.InvokeFamilyTest do
  # M97 §5.2, §6.1: the server's side of a computer's invocations, in its
  # peer, with the session stood in for by the test: what the family sends
  # the computer arrives as `{:mobile_event, frame}`.
  use ExUnit.Case, async: true

  alias FermixChannels.Desktop.InvokeFamily
  alias FermixCore.Computers.Calls

  @device "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"

  setup do
    suffix = System.unique_integer([:positive])
    peers = :"invoke_family_peers_#{suffix}"
    calls = :"invoke_family_calls_#{suffix}"
    start_supervised!({Elixir.Registry, keys: :unique, name: peers})
    start_supervised!({Calls, name: calls})

    {:ok, _owner} =
      Elixir.Registry.register(peers, @device, %{
        session: self(),
        connected_since: DateTime.utc_now()
      })

    %{peers: peers, calls: calls}
  end

  defp init(ctx) do
    {:ok, state} =
      InvokeFamily.init(%{
        device_id: @device,
        session: self(),
        peer: self(),
        registry: ctx.peers,
        options: [calls: ctx.calls, home: System.tmp_dir!()]
      })

    state
  end

  defp waited_on(ctx, id) do
    :ok =
      Calls.register(ctx.calls, %{
        id: id,
        device_id: @device,
        capability: "files",
        op: "read",
        caller: self(),
        effect?: false,
        started_at: DateTime.utc_now(),
        deadline_at: nil
      })
  end

  test "a new session tells everyone still waiting on the computer, and asks nothing itself",
       ctx do
    waited_on(ctx, "inv-a")
    waited_on(ctx, "inv-b")
    _state = init(ctx)

    assert_receive {:computer_invoke, "inv-a", :reconnected}
    assert_receive {:computer_invoke, "inv-b", :reconnected}
    refute_received {:mobile_event, %{"t" => "invoke_status"}}
  end

  # The real link, held by the test just before the request goes: the
  # moment a new session can start in.
  defmodule HeldLink do
    @moduledoc false
    @behaviour FermixCore.Computers.Transport

    alias FermixChannels.Desktop.InvokeTransport

    @impl true
    def open(device_id, header, payload, part, opts) do
      send(Keyword.fetch!(opts, :test), {:opening, header["id"], self()})
      receive do: (:go -> :ok)
      InvokeTransport.open(device_id, header, payload, part, opts)
    end

    @impl true
    def cancel(device_id, about, opts), do: InvokeTransport.cancel(device_id, about, opts)

    @impl true
    def status(device_id, about, opts), do: InvokeTransport.status(device_id, about, opts)
  end

  # M97 §6.3 and tla/specs/computer_invoke: the computer is asked about a
  # request only once it was sent, so its answer that it has no record is
  # never followed by the request itself.
  test "a session that starts before a request is sent asks about it only after it", ctx do
    computer = %FermixCore.Computers.Computer{
      device_id: @device,
      name: "studio Mac",
      connected: true,
      offers: [%{id: "files", state: :on, sentence: nil, detail: nil}]
    }

    turn = %{session_id: "main-44", computer_use_origin: :interactive, source_trust: :operator}

    opts = [
      calls: ctx.calls,
      transport: {HeldLink, [test: self(), registry: ctx.peers]},
      epoch: 3
    ]

    alias FermixCore.Computers.Capabilities.System, as: Echo

    task =
      Task.async(fn ->
        FermixCore.Computers.call(computer, Echo, "echo", %{"text" => "hi"}, turn, opts)
      end)

    assert_receive {:opening, id, caller}
    state = init(ctx)
    send(caller, :go)

    assert_receive {:mobile_event, %{"t" => first, "id" => ^id}}
    assert first == "invoke_open"

    assert_receive {:mobile_event,
                    %{
                      "t" => "invoke_status",
                      "id" => ^id,
                      "capability" => "system",
                      "op" => "echo"
                    }}

    fields = %{"id" => id, "status" => "ok", "duration_ms" => 2}
    {:ok, _state} = InvokeFamily.handle_event("invoke_result", fields, ~s({"text":"hi"}), state)
    assert {:ok, %FermixCore.Computers.Outcome{status: :ok}} = Task.await(task)
  end

  test "an answer goes to the one who waits on it", ctx do
    waited_on(ctx, "inv-r")
    state = init(ctx)
    fields = %{"id" => "inv-r", "status" => "ok", "duration_ms" => 4}

    assert {:ok, _state} = InvokeFamily.handle_event("invoke_result", fields, ~s({"a":1}), state)
    assert_receive {:computer_invoke, "inv-r", {:result, ^fields, ~s({"a":1})}}
  end

  test "an answer's part is put back together, its progress told every sixteen frames", ctx do
    waited_on(ctx, "inv-p")
    state = init(ctx)
    chunks = for n <- 1..17, do: :binary.copy(<<n>>, 1_000)
    size = 17_000

    state =
      chunks
      |> Enum.with_index()
      |> Enum.reduce(state, fn {bytes, index}, state ->
        fields = %{"id" => "inv-p", "index" => index, "last" => index == 16, "size_bytes" => size}
        {:ok, state} = InvokeFamily.handle_event("invoke_part", fields, bytes, state)
        state
      end)

    assert_receive {:computer_invoke, "inv-p", {:part, {:progress, 16_000, 17_000}}}
    whole = IO.iodata_to_binary(chunks)
    assert_receive {:computer_invoke, "inv-p", {:part, {:done, ^whole}}}
    assert state.parts == %{}
  end

  test "a part with a gap or past its size is told failed, and its later frames dropped", ctx do
    waited_on(ctx, "inv-g")
    state = init(ctx)
    assert_receive {:computer_invoke, "inv-g", :reconnected}
    frame = %{"id" => "inv-g", "size_bytes" => 6}

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, state} =
        InvokeFamily.handle_event(
          "invoke_part",
          Map.merge(frame, %{"index" => 1, "last" => false}),
          "abc",
          state
        )

      assert_receive {:computer_invoke, "inv-g",
                      {:part, {:error, "The answer's file did not arrive whole."}}}

      {:ok, state} =
        InvokeFamily.handle_event(
          "invoke_part",
          Map.merge(frame, %{"index" => 2, "last" => true}),
          "def",
          state
        )

      refute_received {:computer_invoke, "inv-g", _message}
      assert state.parts == %{}

      too_big = %{"id" => "inv-g", "size_bytes" => 2, "index" => 0, "last" => true}
      {:ok, _state} = InvokeFamily.handle_event("invoke_part", too_big, "abc", state)
      assert_receive {:computer_invoke, "inv-g", {:part, {:error, _sentence}}}
    end)
  end

  describe "the home's services a computer asks for" do
    defp open(id, capability, op, args) do
      %{
        "id" => id,
        "capability" => capability,
        "op" => op,
        "deadline_ms" => 10_000,
        "epoch" => 3,
        "origin" => "computer",
        "args" => args
      }
    end

    test "an echo is run and answered", ctx do
      state = init(ctx)
      fields = open("inv-e", "system", "echo", nil) |> Map.delete("args")

      {:ok, _state} =
        InvokeFamily.handle_event("invoke_open", fields, ~s({"text":"from the computer"}), state)

      assert_receive {:mobile_event,
                      %{"t" => "invoke_result", "id" => "inv-e", "status" => "ok"} = frame},
                     10_000

      assert frame["bytes"] =~ "from the computer"
      assert_receive {:desktop_family, :invoke, {:service_done, "inv-e"}}, 10_000
    end

    test "what the server does not offer is unavailable, and an unknown id unknown", ctx do
      state = init(ctx)
      fields = open("inv-x", "browser", "open", nil) |> Map.delete("args")
      {:ok, state} = InvokeFamily.handle_event("invoke_open", fields, "{}", state)

      assert_receive {:mobile_event,
                      %{"t" => "invoke_result", "id" => "inv-x", "refusal" => "unavailable"}}

      {:ok, _state} = InvokeFamily.handle_event("invoke_status", %{"id" => "inv-y"}, <<>>, state)

      assert_receive {:mobile_event,
                      %{"t" => "invoke_result", "id" => "inv-y", "status" => "unknown"}}
    end
  end
end
