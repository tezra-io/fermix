defmodule FermixCore.OpenLoops.CheckInTest do
  # Not async: the real `open_loop_respond` runs only while open loops are
  # enabled, an app-env switch this module turns on and restores.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.ConversationStore
  alias FermixCore.Memory.Repo
  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.CheckIn
  alias FermixCore.OpenLoops.CheckInSupervisor
  alias FermixCore.Tools.OpenLoopRespond
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TelemetryCapture

  @tz "America/New_York"
  # Every value here is invented. June 2031 is EDT (UTC-4); the default active
  # hours are 09:00-21:00 local, 13:00Z-01:00Z.
  @said_at ~U[2031-06-02 14:00:00Z]
  @due_at ~U[2031-06-07 13:00:00Z]
  @now ~U[2031-06-07 17:00:00Z]
  @hours %{start: ~T[09:00:00], finish: ~T[21:00:00], source: :default, sample: 0}
  @message "On Monday you said you'd send the Harbourview grant report by the 10th; " <>
             "three days are left. Want me to draft the cover note, or is it already on its way?"

  @start [:fermix, :open_loop, :checkin, :start]
  @complete [:fermix, :open_loop, :checkin, :complete]
  @error [:fermix, :open_loop, :checkin, :error]
  @skipped [:fermix, :open_loop, :skipped]
  @settled [:fermix, :open_loop, :settled]

  # The channel seam: the loop's destination IS a named Agent, so the run's one
  # message can be observed without any test-only send option.
  defmodule ScriptedChannel do
    @moduledoc false

    def send_message(destination, text, opts) do
      destination
      |> String.to_existing_atom()
      |> Agent.get_and_update(fn state ->
        {result, rest} = next(state.script)
        {result, %{state | script: rest, calls: state.calls ++ [%{text: text, opts: opts}]}}
      end)
    end

    defp next([]), do: {:ok, []}
    defp next([observe | tail]) when is_function(observe, 0), do: {observe.(), tail}
    defp next([head | tail]), do: {head, tail}
  end

  # The storage seam for a race no scripted turn can reach: every call goes on
  # to the real repo, and each budget spend first runs `before_spend`, as an
  # owner's answer landing between the run's re-read and its spend.
  defmodule RepoProxy do
    @moduledoc false

    use GenServer

    def start_link({name, repo, before_spend}),
      do: GenServer.start_link(__MODULE__, %{repo: repo, before_spend: before_spend}, name: name)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(
          {:spend_open_loop_budget, _id, _claimed_at, _since, _now} = request,
          _from,
          state
        ) do
      state.before_spend.()
      {:reply, GenServer.call(state.repo, request), state}
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.repo, request), state}
  end

  # The provider seam: a scripted turn list, no network. Each turn is plain
  # text, a list of `open_loop_respond` calls, or `:park` (never answers, so
  # only the watchdog ends the run). The prompt and the offered tools are
  # echoed back so both are asserted where the model sees them.
  defmodule ScriptedProvider do
    @moduledoc false

    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(messages, capabilities, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_chat, messages, names(capabilities)})
      opts |> Keyword.get(:before_reply, fn -> :ok end) |> then(& &1.())
      reply(Keyword.fetch!(opts, :script))
    end

    @impl true
    def continue(%{rest: rest}, _tool_results, _opts), do: reply(rest)

    @impl true
    def to_provider_tools(capabilities), do: capabilities

    @impl true
    def parse_tool_calls(_response), do: []

    @impl true
    def parse_response(response), do: response

    @impl true
    def supports_streaming?, do: false

    defp reply([]), do: reply([{:text, ""}])

    defp reply([:park | _rest]) do
      receive do
        :never_sent -> {:error, "parked"}
      end
    end

    defp reply([{:text, text} | rest]), do: {:ok, turn(text, [], rest)}

    defp reply([{:respond, calls} | rest]) do
      tool_calls =
        calls
        |> Enum.with_index(1)
        |> Enum.map(fn {args, n} ->
          %{id: "fc_#{n}", call_id: "call_#{n}", name: "open_loop_respond", arguments: args}
        end)

      {:ok, turn("", tool_calls, rest)}
    end

    defp turn(content, tool_calls, rest) do
      %{
        content: content,
        tool_calls: tool_calls,
        usage: %{prompt_tokens: 1, completion_tokens: 1, total_tokens: 2},
        model: "mock",
        provider_state: %{rest: rest}
      }
    end

    defp names(capabilities), do: Enum.map(capabilities, & &1.name)
  end

  setup do
    unique = System.unique_integer([:positive])
    dir = SafeRm.make_tmp_dir!("open-loops-checkin")
    db_path = Path.join(dir, "memory.db")
    repo = :"open_loops_checkin_repo_#{unique}"
    registry = :"open_loops_checkin_caps_#{unique}"
    supervisor = :"open_loops_checkin_sup_#{unique}"
    store = :"open_loops_checkin_store_#{unique}"
    tasks = :"open_loops_checkin_tasks_#{unique}"
    channel = :"open_loops_checkin_channel_#{unique}"

    start_supervised!({Repo, name: repo, enabled: true, database_path: db_path})
    start_supervised!({CapabilityRegistry, name: registry})
    start_supervised!({CheckInSupervisor, name: supervisor})
    start_supervised!({Task.Supervisor, name: tasks})

    start_supervised!(
      {ConversationStore, name: store, repo: repo, durable_task_supervisor: tasks}
    )

    bootstrap = Path.join(dir, "bootstrap")
    File.mkdir_p!(Path.join(bootstrap, "main"))
    File.write!(Path.join(bootstrap, "main/IDENTITY.md"), "Identity marker: Quillfeather.")
    File.write!(Path.join(bootstrap, "main/SOUL.md"), "Soul marker: unhurried and warm.")
    File.write!(Path.join(bootstrap, "main/FERMIX.md"), "Fermix marker: tool routing table.")

    register_tools(registry)
    previous = Application.fetch_env(:fermix_core, :open_loops)
    Application.put_env(:fermix_core, :open_loops, enabled: true)

    on_exit(fn ->
      restore_open_loops(previous)
      SafeRm.rm_rf!(dir)
    end)

    %{
      repo: repo,
      registry: registry,
      supervisor: supervisor,
      store: store,
      tasks: tasks,
      channel: channel,
      bootstrap: bootstrap
    }
  end

  defp restore_open_loops({:ok, value}), do: Application.put_env(:fermix_core, :open_loops, value)
  defp restore_open_loops(:error), do: Application.delete_env(:fermix_core, :open_loops)

  # The real outcome tool, the run's other two tools as stand-ins, and decoys a
  # check-in must never be offered.
  defp register_tools(registry) do
    :ok = CapabilityRegistry.register(registry, Builtin.from_tool_module(OpenLoopRespond))

    for name <- [
          "memory_recall",
          "open_loop_list",
          "memory_store",
          "event_list",
          "send_to_channel"
        ] do
      :ok =
        CapabilityRegistry.register(
          registry,
          Capability.new(%{
            name: name,
            description: "Test capability #{name}",
            parameters: %{"type" => "object", "properties" => %{}},
            kind: :builtin,
            executor: {__MODULE__, :echo, []},
            policy_class: :read_only
          })
        )
    end
  end

  def echo(_args, _context), do: {:ok, %{success: true, output: "nothing relevant"}}

  defp loop_id do
    "loop_" <> (8 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp start_channel(ctx, script) do
    start_supervised!(%{
      id: {:channel, ctx.channel},
      start: {Agent, :start_link, [fn -> %{script: script, calls: []} end, [name: ctx.channel]]},
      restart: :temporary
    })
  end

  defp calls(ctx), do: Agent.get(ctx.channel, & &1.calls)

  # A medium loop (the 10th; slots the 7th, 9th and 11th at 09:00 EDT), due and
  # claimed by the time the run starts, as the scheduler hands it over.
  defp claimed_loop!(ctx, overrides \\ %{}) do
    id = loop_id()

    attrs =
      Map.merge(
        %{
          id: id,
          agent_id: "main",
          owner_id: "default",
          dedupe_key: "send the harbourview grant report #{id}",
          intention: "Send the Harbourview grant report",
          why_it_matters: "the foundation releases the second tranche on receipt",
          matters_by_kind: "date",
          matters_by_date: ~D[2031-06-10],
          matters_by_time: nil,
          matters_by_at: ~U[2031-06-11 04:00:00Z],
          timezone: @tz,
          horizon_class: "medium",
          said_at: @said_at,
          source_channel: "telegram",
          source_chat_id: "40001",
          source_thread_scope: "root",
          next_touch_at: @due_at,
          delivery_platform: "telegram",
          delivery_destination: Atom.to_string(ctx.channel),
          delivery_thread_scope: "root",
          created_at: @said_at
        },
        overrides
      )

    {:ok, {:created, _row}} = Repo.create_open_loop(attrs, server: ctx.repo)
    {:ok, _scan} = Repo.scan_due_open_loops(@due_at, 50, server: ctx.repo)
    {:ok, claimed} = Repo.claim_open_loop_checkin(id, @now, server: ctx.repo)
    claimed
  end

  defp args(ctx, loop, overrides) do
    Map.merge(
      %{
        loop: loop,
        claimed_at: loop.claimed_at,
        touch: loop.touches + 1,
        rung: 2,
        active_hours: @hours,
        repo: ctx.repo,
        delivery_opts: [adapter: ScriptedChannel],
        capability_registry: ctx.registry,
        adapter: ScriptedProvider,
        adapter_opts: [test_pid: self(), script: [{:text, ""}]],
        conversation_store: ctx.store,
        now_fn: fn -> @now end,
        bootstrap_dir: ctx.bootstrap
      },
      overrides
    )
  end

  defp script(steps), do: %{adapter_opts: [test_pid: self(), script: steps]}

  defp respond(decision), do: {:respond, [Jason.encode!(decision)]}

  defp capture(loop) do
    TelemetryCapture.attach([@start, @complete, @error, @skipped, @settled],
      open_loop_id: loop.id
    )
  end

  # The run's own exit is its completion signal; it closes its trace before it
  # exits, so the bookend is already waiting.
  defp run!(ctx, loop, overrides) do
    {:ok, pid} = CheckInSupervisor.start_checkin(ctx.supervisor, args(ctx, loop, overrides))
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
    assert reason in [:normal, :noproc], "the check-in exited #{inspect(reason)}"
  end

  defp bookend do
    assert_receive {:telemetry, event, measurements, metadata} when event in [@complete, @error]
    {List.last(event), measurements, metadata}
  end

  defp stored(ctx, loop) do
    {:ok, row} = Repo.get_open_loop(loop.id, server: ctx.repo)
    row
  end

  # The history row's durable write runs on the store's task supervisor; every
  # task it started has finished once each one's `:DOWN` arrives.
  defp await_durable_writes(ctx) do
    for pid <- Task.Supervisor.children(ctx.tasks) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 10_000
    end

    :ok
  end

  describe "decisions" do
    test "speak sends once, writes the history row, then advances the ledger", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)

      run!(ctx, loop, script([respond(%{decision: "speak", message: @message})]))

      assert {:complete, measurements, metadata} = bookend()
      assert metadata.outcome == "spoke"
      assert is_integer(measurements.duration_ms)
      assert metadata.session_id == "open_loop_#{loop.id}_1"

      assert [%{text: @message, opts: opts}] = calls(ctx)
      assert Keyword.fetch!(opts, :proactive_key) == "open_loop:#{loop.id}:1"

      key = {"telegram", Atom.to_string(ctx.channel), :root}
      history = ConversationStore.get_history(key, server: ctx.store)
      assert [%{role: "assistant", content: @message}] = history

      :ok = await_durable_writes(ctx)

      {:ok, [row]} =
        Repo.get_messages(
          %{agent_id: "main", channel: "telegram", chat_id: elem(key, 1), thread_scope: :root},
          server: ctx.repo
        )

      assert row.kind == "chat_message"
      assert row.metadata["open_loop_checkin"] == loop.id

      assert %{
               state: "asked",
               touches: 1,
               last_touch_rung: 2,
               last_outcome: "spoke",
               last_message: @message,
               claimed_at: nil
             } = stored(ctx, loop)

      assert_received {:telemetry, @settled, _measurements,
                       %{from: "due", to: "asked", by: "checkin"}}
    end

    test "speak spends the day's budget on its claim before the one send", ctx do
      test_pid = self()
      repo = ctx.repo
      loop = claimed_loop!(ctx)

      at_send = fn ->
        send(test_pid, {:at_send, Repo.get_open_loop(loop.id, server: repo)})
        :ok
      end

      start_channel(ctx, [at_send])

      run!(ctx, loop, script([respond(%{decision: "speak", message: @message})]))

      assert_receive {:at_send, {:ok, at_send_row}}
      assert %{state: "due", last_outcome: nil} = at_send_row
      assert DateTime.compare(at_send_row.claimed_at, loop.claimed_at) == :eq
      assert DateTime.compare(at_send_row.last_rung2_at, @now) == :eq

      row = stored(ctx, loop)
      assert %{state: "asked", last_outcome: "spoke"} = row
      assert DateTime.compare(row.last_rung2_at, @now) == :eq
    end

    test "silent sends nothing and advances the slot", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)

      run!(ctx, loop, script([respond(%{decision: "silent"})]))

      assert {:complete, _measurements, %{outcome: "silent"}} = bookend()
      assert calls(ctx) == []

      row = stored(ctx, loop)
      assert %{state: "open", touches: 0, last_outcome: "silent", claimed_at: nil} = row
      assert DateTime.compare(row.next_touch_at, ~U[2031-06-09 13:00:00Z]) == :eq
    end

    test "close settles the loop as reported elsewhere", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)

      run!(
        ctx,
        loop,
        script([respond(%{decision: "close", reason: "memory says the report was sent"})])
      )

      assert {:complete, _measurements, %{outcome: "closed"}} = bookend()
      assert calls(ctx) == []

      assert %{state: "closed", close_reason: "reported_elsewhere", last_outcome: "closed"} =
               stored(ctx, loop)

      session_id = "open_loop_#{loop.id}_1"

      assert_received {:telemetry, @settled, _measurements,
                       %{from: "due", to: "closed", by: "checkin", session_id: ^session_id}}
    end

    test "no decision is empty: an anomaly, nothing sent", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)

      {_result, log} =
        with_log(fn -> run!(ctx, loop, script([{:text, "Here is my reply to the owner."}])) end)

      assert {:complete, _measurements, %{outcome: "empty"}} = bookend()
      assert log =~ "without an open_loop_respond decision"
      assert calls(ctx) == []
      assert %{state: "open", touches: 0, last_outcome: "empty"} = stored(ctx, loop)
    end

    test "the first decision is kept and a later one ignored", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)

      run!(
        ctx,
        loop,
        script([
          respond(%{decision: "silent"}),
          respond(%{decision: "speak", message: @message})
        ])
      )

      assert {:complete, _measurements, %{outcome: "silent"}} = bookend()
      assert calls(ctx) == []
      assert %{last_outcome: "silent", touches: 0} = stored(ctx, loop)
    end

    # The tool refuses a message past the bound rather than cutting it; a model
    # that then stops without deciding leaves the run `empty`.
    test "an over-long message is refused at the tool, so the run ends empty", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)

      long = String.duplicate("a", 1_801)

      {_result, _log} =
        with_log(fn ->
          run!(ctx, loop, script([respond(%{decision: "speak", message: long}), {:text, ""}]))
        end)

      assert {:complete, _measurements, %{outcome: "empty"}} = bookend()
      assert calls(ctx) == []
    end
  end

  describe "failures" do
    test "a send failure is delivery_failed: touches unchanged, re-armed, the budget spent",
         ctx do
      start_channel(ctx, [{:error, {:permanent, :authentication}}])
      loop = claimed_loop!(ctx)
      capture(loop)

      {_result, _log} =
        with_log(fn ->
          run!(ctx, loop, script([respond(%{decision: "speak", message: @message})]))
        end)

      assert {:complete, _measurements, %{outcome: "delivery_failed"}} = bookend()
      assert length(calls(ctx)) == 1

      row = stored(ctx, loop)
      assert %{state: "open", touches: 0, last_outcome: "delivery_failed", claimed_at: nil} = row
      # The next active-hours start: 09:00 EDT the next day.
      assert DateTime.compare(row.next_touch_at, ~U[2031-06-08 13:00:00Z]) == :eq
      # The budget was spent before the attempt: a message the platform may have
      # shown anyway costs the owner a quiet day, never a second message.
      assert DateTime.compare(row.last_rung2_at, @now) == :eq

      key = {"telegram", Atom.to_string(ctx.channel), :root}
      assert ConversationStore.get_history(key, server: ctx.store) == []
    end

    test "a day another of the owner's loops already spent is refused at the spend", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      other = claimed_loop!(ctx, %{intention: "Book the Marlow Street boiler inspection"})
      day_start = ActiveHours.day_start(@now, @tz)

      {:ok, _other} =
        Repo.spend_open_loop_budget(other.id, other.claimed_at, day_start, @now, server: ctx.repo)

      capture(loop)

      {_result, _log} =
        with_log(fn ->
          run!(ctx, loop, script([respond(%{decision: "speak", message: @message})]))
        end)

      # The layer above (one run per owner) should have held this run back; the
      # single writer refuses anyway, and the run is a fault, never a message.
      assert {:error, _measurements, %{status: "error", error: error}} = bookend()
      assert error =~ "budget_spent"
      assert calls(ctx) == []

      row = stored(ctx, loop)

      assert %{
               state: "open",
               touches: 0,
               last_outcome: "error",
               claimed_at: nil,
               last_rung2_at: nil
             } =
               row

      # Re-armed at the next active-hours start, which the spent day holds to tomorrow.
      assert DateTime.compare(row.next_touch_at, ~U[2031-06-08 13:00:00Z]) == :eq
      assert %{last_rung2_at: spent_at} = stored(ctx, other)
      assert DateTime.compare(spent_at, @now) == :eq

      key = {"telegram", Atom.to_string(ctx.channel), :root}
      assert ConversationStore.get_history(key, server: ctx.store) == []
    end

    test "an owner who settles the loop mid-run means closed_meanwhile and no send", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)
      repo = ctx.repo

      owner_settles = fn ->
        {:ok, _row} =
          Repo.settle_open_loop(
            loop.id,
            %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil},
            server: repo
          )
      end

      {_result, _log} =
        with_log(fn ->
          run!(ctx, loop, %{
            adapter_opts: [
              test_pid: self(),
              before_reply: owner_settles,
              script: [respond(%{decision: "speak", message: @message})]
            ]
          })
        end)

      assert_received {:telemetry, @skipped, _measurements, %{reason: "closed_meanwhile"}}
      assert {:complete, _measurements, %{outcome: "silent"}} = bookend()
      assert calls(ctx) == []
      assert %{state: "closed", close_reason: "done", last_outcome: nil} = stored(ctx, loop)
    end

    test "an owner who settles the loop just before the spend means no spend and no send",
         ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)
      repo = ctx.repo
      proxy = :"#{repo}_proxy"

      owner_settles = fn ->
        {:ok, _row} =
          Repo.settle_open_loop(
            loop.id,
            %{state: "closed", close_reason: "done", closed_at: @now, next_touch_at: nil},
            server: repo
          )
      end

      start_supervised!({RepoProxy, {proxy, repo, owner_settles}})

      {_result, _log} =
        with_log(fn ->
          run!(ctx, loop, %{
            repo: proxy,
            adapter_opts: [
              test_pid: self(),
              script: [respond(%{decision: "speak", message: @message})]
            ]
          })
        end)

      assert_received {:telemetry, @skipped, _measurements, %{reason: "closed_meanwhile"}}
      assert {:complete, _measurements, %{outcome: "silent"}} = bookend()
      assert calls(ctx) == []

      assert %{state: "closed", close_reason: "done", last_outcome: nil, last_rung2_at: nil} =
               stored(ctx, loop)
    end

    test "a run past its watchdog is killed and closed as a timeout", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)
      capture(loop)

      {_result, _log} =
        with_log(fn -> run!(ctx, loop, Map.merge(script([:park]), %{timeout_ms: 50})) end)

      assert {:error, _measurements, %{status: "timeout"}} = bookend()
      assert_received {:telemetry, @start, _measurements, %{max_duration_ms: 50}}
      assert calls(ctx) == []
      assert %{state: "open", touches: 0, last_outcome: "timeout"} = stored(ctx, loop)
    end
  end

  describe "the prompt and the tool surface" do
    test "the model sees IDENTITY, SOUL and the guidance, never FERMIX.md", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)

      run!(ctx, loop, script([respond(%{decision: "silent"})]))

      assert_receive {:provider_chat, messages, _tools}

      system =
        messages |> Enum.filter(&(&1.role == "system")) |> Enum.map_join("\n", & &1.content)

      user = messages |> Enum.filter(&(&1.role == "user")) |> Enum.map_join("\n", & &1.content)

      assert system =~ "Identity marker: Quillfeather."
      assert system =~ "Soul marker: unhurried and warm."
      assert system =~ "You are a Fermix check-in."
      refute system =~ "Fermix marker"

      # The occasion opens with the current time on the owner's clock (no zone is
      # configured here, so UTC), then the facts.
      [now_line, _header, json] = String.split(user, "\n\n", parts: 3)
      assert now_line == "Now: Saturday, June 7, 2031 at 5:00 PM UTC."
      facts = Jason.decode!(json)
      assert facts["open_loop"]["open_loop_id"] == loop.id
      assert facts["touch"] == 1
      assert facts["repeat"] == false
      assert facts["last_touch"] == false
      refute Map.has_key?(facts, "previous_message")
    end

    test "a repeat carries the message the owner last received", ctx do
      start_channel(ctx, [:ok])

      loop =
        claimed_loop!(ctx)
        |> then(fn claimed ->
          {:ok, _row} =
            Repo.finalize_open_loop_checkin(
              claimed.id,
              claimed.claimed_at,
              %{
                state: "asked",
                touches: 1,
                next_touch_at: ~U[2031-06-09 13:00:00Z],
                last_touch_at: @now,
                last_touch_rung: 2,
                last_outcome: "spoke",
                last_outcome_at: @now,
                last_message: @message
              },
              server: ctx.repo
            )

          {:ok, _scan} = Repo.scan_due_open_loops(~U[2031-06-09 13:00:00Z], 50, server: ctx.repo)

          {:ok, reclaimed} =
            Repo.claim_open_loop_checkin(claimed.id, ~U[2031-06-09 17:00:00Z], server: ctx.repo)

          reclaimed
        end)

      run!(ctx, loop, script([respond(%{decision: "silent"})]))

      assert_receive {:provider_chat, messages, _tools}
      user = messages |> Enum.filter(&(&1.role == "user")) |> Enum.map_join("\n", & &1.content)
      # The occasion opens with the current time on the owner's clock (no zone is
      # configured here, so UTC), then the facts.
      [now_line, _header, json] = String.split(user, "\n\n", parts: 3)
      assert now_line == "Now: Saturday, June 7, 2031 at 5:00 PM UTC."
      facts = Jason.decode!(json)

      assert facts["touch"] == 2
      assert facts["repeat"] == true
      assert facts["previous_message"] == @message
    end

    test "the tool set offered is exactly the three", ctx do
      start_channel(ctx, [:ok])
      loop = claimed_loop!(ctx)

      run!(ctx, loop, script([respond(%{decision: "silent"})]))

      assert_receive {:provider_chat, _messages, tools}
      assert Enum.sort(tools) == ["memory_recall", "open_loop_list", "open_loop_respond"]
    end

    test "the loop context is the delivery target's, operator-trusted, marked as a check-in",
         ctx do
      loop = claimed_loop!(ctx)
      ref = make_ref()

      context = CheckIn.loop_context(%{loop: loop, touch: 1, repo: ctx.repo, ref: ref})

      assert context.conversation_key == {"telegram", loop.delivery_destination, :root}
      assert context.session_id == "open_loop_#{loop.id}_1"
      assert context.agent_name == "open_loop:#{loop.id}"
      assert context.source_trust == :operator
      assert context.memory_repo == ctx.repo
      assert context.memory_owner_id == "default"
      assert context.open_loop_checkin == %{id: loop.id, reply_to: self(), ref: ref}
      refute Map.has_key?(context, :computer_use_origin)
    end
  end
end
