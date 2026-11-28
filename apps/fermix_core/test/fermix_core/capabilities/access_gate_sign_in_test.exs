defmodule FermixCore.Capabilities.AccessGateSignInTest do
  @moduledoc """
  M84's half of the access gate: the `:sign_in` kind, which runs or refuses and
  never parks; a job naming `browser`, set up only where a sign-in could run;
  and `ask_in_call/3`, which asks the owner from inside the sign-in's own call
  and waits there for the answer (`Browser.SignIn` is its caller).

  Each test parks in its own `AccessGate.Pending`, handed through the context
  (`:access_pending`), so no record meets another test's.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Timeouts
  alias FermixCore.Tools.Browser
  alias FermixCore.Tools.Shell
  alias FermixTestSupport.TelemetryCapture

  @token "TOKEN123"
  @sign_in %{
    "action" => "act",
    "kind" => "sign_in",
    "target" => "t1",
    "site" => "github.com",
    "username_ref" => 3,
    "password_ref" => 4
  }
  @prompt "Sign in to github.com as alice@example.com?"

  # The rows of the jobs a scheduled context below can be a run of. The lookup
  # hands the run's `:memory_repo` on as `server:`, which `scheduled/2` sets to
  # the test process, so a test sees whether the gate read the row.
  defmodule BrowserJobs do
    def get_job(_id, opts) do
      send(Keyword.fetch!(opts, :server), :job_row_read)
      {:ok, %{allowed_tools: ["web_search", "browser"]}}
    end
  end

  defmodule SearchJobs do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: ["web_search"]}}
  end

  # A job with no list of its own: its runs reach the whole operator surface,
  # `browser` among it, and its row names nothing.
  defmodule OpenJobs do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: []}}
  end

  setup do
    sid = "sign-in-#{System.unique_integer([:positive])}"
    pending = :"sign_in_pending_#{System.unique_integer([:positive])}"
    start_supervised!({Pending, name: pending})

    TelemetryCapture.attach([[:fermix, :tool, :exec], [:fermix, :timeout, :expired]],
      session_id: sid
    )

    %{sid: sid, pending: pending}
  end

  defp browser, do: Builtin.from_tool_module(Browser)

  defp chat(ctx, extra \\ %{}) do
    test_pid = self()

    Map.merge(
      %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        session_id: ctx.sid,
        agent_name: "main",
        conversation_key: {"telegram", ctx.sid, :root},
        chat_type: "private",
        access_pending: ctx.pending,
        outside_sources: MapSet.new(),
        reply_fn: fn part -> send(test_pid, {:reply, part}) end,
        approval_fn: fn request ->
          send(test_pid, {:approval, request, self()})
          {:ok, @token, :new}
        end
      },
      extra
    )
  end

  defp voice(ctx) do
    %{
      source_trust: :operator,
      computer_use_origin: :voice,
      session_id: ctx.sid,
      agent_name: "main",
      voice_call_id: "call-#{ctx.sid}",
      access_pending: ctx.pending,
      outside_sources: MapSet.new()
    }
  end

  defp inbox_only(ctx, answer) do
    test_pid = self()

    ctx
    |> chat()
    |> Map.drop([:approval_fn])
    |> Map.put(:owner_inbox_approval_fn, fn request ->
      send(test_pid, {:owner_inbox, request, self()})
      answer
    end)
  end

  defp scheduled(ctx, jobs \\ BrowserJobs) do
    %{
      source_trust: :operator,
      session_id: ctx.sid,
      conversation_key: {:scheduled_job, "job_x", "run_1"},
      job_id: "job_x",
      jobs_registry: jobs,
      memory_repo: self(),
      access_pending: ctx.pending,
      outside_sources: MapSet.new()
    }
  end

  defp held_text({:held, %{success: false, error: text}}), do: text

  defp refused?(context, code) do
    assert held_text(AccessGate.admit(browser(), @sign_in, context)) =~ "(#{code})"
    assert_receive {:telemetry, [:fermix, :tool, :exec], _measurements, metadata}
    assert metadata.access_gate == "refused_#{code}"
    assert metadata.policy_enforcement == AccessGate.pre_execution_marker(:deny)
    refute_received {:telemetry, [:fermix, :tool, :exec], _, _}
    true
  end

  describe "gate_kind/2" do
    test "a built-in browser act of kind sign_in is the :sign_in kind" do
      assert AccessGate.gate_kind(browser(), @sign_in) == :sign_in
    end

    test "every other browser call, and a look-alike tool, is none of the gate's kinds" do
      assert AccessGate.gate_kind(browser(), %{"action" => "act", "kind" => "click"}) == nil
      assert AccessGate.gate_kind(browser(), %{"action" => "snapshot"}) == nil
      assert AccessGate.gate_kind(browser(), %{}) == nil

      look_alike =
        Capability.new(%{
          name: "browser",
          description: "A plugin tool with the same name.",
          parameters: %{"type" => "object"},
          kind: :mcp,
          executor: {__MODULE__, :never, []},
          policy_class: :external_api,
          metadata: %{plugin_owned?: true, plugin: "other"}
        })

      assert AccessGate.gate_kind(look_alike, @sign_in) == nil
    end

    test "the two command kinds are unchanged" do
      assert AccessGate.gate_kind(Builtin.from_tool_module(Shell), %{}) == :host_command

      flagged =
        Capability.new(%{
          name: "tesla_unlock_doors",
          description: "Unlock the car's doors.",
          parameters: %{"type" => "object"},
          kind: :mcp,
          executor: {__MODULE__, :never, []},
          policy_class: :external_api,
          metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "tesla"}
        })

      assert AccessGate.gate_kind(flagged, @sign_in) == :access_sensitive
    end
  end

  describe "admission" do
    test "the owner's own attended turn is admitted, even after reading outside content", ctx do
      tainted = MapSet.new([{:tool, "web_fetch"}])

      for context <- [
            chat(ctx),
            chat(ctx, %{outside_sources: tainted}),
            chat(ctx, %{channel: "companion", chat_type: nil}),
            chat(ctx, %{channel: "mobile", chat_type: nil})
          ] do
        assert {:dispatch, %{access_gate: "direct"}} =
                 AccessGate.admit(browser(), @sign_in, context)
      end

      # The gate itself never parks a sign-in or asks the owner: the call asks.
      refute_received {:approval, _, _}
      refute_received {:telemetry, [:fermix, :tool, :exec], _, _}
      assert :none = Pending.pending_from(ctx.sid, ctx.pending)
    end

    test "a delegated worker is refused", ctx do
      assert refused?(chat(ctx, %{subagent_depth: 1}), "sign_in_not_allowed")
      assert refused?(chat(ctx, %{skill_depth: 1}), "sign_in_not_allowed")
    end

    test "a scheduled run of the owner's signs in when its job row names browser", ctx do
      assert {:dispatch, %{access_gate: "scheduled"} = admitted} =
               AccessGate.admit(browser(), @sign_in, scheduled(ctx))

      assert_received :job_row_read
      assert AccessGate.job_sign_in?(admitted)

      # The gate asks no one and emits nothing: the call's own event follows.
      refute_received {:approval, _, _}
      refute_received {:telemetry, [:fermix, :tool, :exec], _, _}
      assert :none = Pending.pending_from(ctx.sid, ctx.pending)

      # A follow-up a watcher set off is a scheduled run, and nothing of the
      # item reaches it.
      watcher_follow_up = Map.put(scheduled(ctx), :trigger, "watcher")

      assert {:dispatch, %{access_gate: "scheduled"}} =
               AccessGate.admit(browser(), @sign_in, watcher_follow_up)
    end

    test "a scheduled run whose job row does not name browser is refused", ctx do
      assert refused?(scheduled(ctx, SearchJobs), "sign_in_not_allowed")
      assert refused?(scheduled(ctx, OpenJobs), "sign_in_not_allowed")

      # Every other browser call of the run is not the gate's to decide.
      assert {:dispatch, context} =
               AccessGate.admit(browser(), %{"action" => "snapshot"}, scheduled(ctx, OpenJobs))

      refute AccessGate.job_sign_in?(context)
    end

    test "the refusal names both ways a sign-in runs", ctx do
      text = held_text(AccessGate.admit(browser(), @sign_in, scheduled(ctx, OpenJobs)))

      assert text =~ "their own chat or the Fermix app"
      assert text =~ "a scheduled job of theirs whose allowed tools name browser"
      refute text =~ "a cue, a scheduled job or"
    end

    test "a guest's scheduled run never signs in, and its job row is never read", ctx do
      assert refused?(%{scheduled(ctx) | source_trust: :guest}, "sign_in_not_allowed")
      refute_received :job_row_read
    end

    test "a worker a scheduled run delegated to never signs in", ctx do
      assert refused?(Map.put(scheduled(ctx), :subagent_depth, 1), "sign_in_not_allowed")
      assert refused?(Map.put(scheduled(ctx), :skill_depth, 1), "sign_in_not_allowed")
      refute_received :job_row_read
    end

    test "only the gate's own stamp of a scheduled run says a job signs in", ctx do
      refute AccessGate.job_sign_in?(chat(ctx))
      refute AccessGate.job_sign_in?(scheduled(ctx))

      {:dispatch, attended} = AccessGate.admit(browser(), @sign_in, chat(ctx))
      refute AccessGate.job_sign_in?(attended)
    end

    test "a run a cue woke never signs in", ctx do
      context = Map.put(scheduled(ctx), :trigger, "cue")

      # The cue surface has no browser, so the run is refused before the gate's
      # own rule; the rule still refuses it should the surface ever widen.
      assert {:held, %{success: false}} = AccessGate.admit(browser(), @sign_in, context)
      assert {:refuse, :sign_in_not_allowed} = AccessGate.decide(browser(), context, @sign_in)
    end

    test "a shared Buzz channel turn is refused", ctx do
      buzz = %{"BUZZ_RELAY_URL" => "wss://relay.example.test", "PATH" => "/usr/bin"}
      assert refused?(chat(ctx, %{session_env: buzz}), "sign_in_not_allowed")
    end

    test "a turn that is not the owner's attended own is refused", ctx do
      for context <- [
            chat(ctx, %{computer_use_origin: :unattended}),
            chat(ctx, %{harness_continuation_depth: 1}),
            chat(ctx, %{source_trust: :guest}),
            Map.delete(chat(ctx), :source_trust),
            Map.delete(chat(ctx), :computer_use_origin)
          ] do
        assert refused?(context, "sign_in_not_allowed")
      end
    end

    test "a voice turn, and a task a voice call delegated, is refused as voice", ctx do
      assert refused?(voice(ctx), "sign_in_not_on_voice")

      delegated = chat(ctx, %{computer_use_origin: :voice, voice_call_id: "call-#{ctx.sid}"})
      assert refused?(delegated, "sign_in_not_on_voice")
    end
  end

  describe "check_job_tools/2 for a job that names browser" do
    setup do
      registry = :"sign_in_caps_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: registry})
      :ok = CapabilityRegistry.register(registry, browser())
      %{registry: registry}
    end

    @job_tools ["web_search", "browser"]
    @read MapSet.new([{:tool, "web_fetch"}])

    defp job_check(context, ctx, names \\ @job_tools),
      do: AccessGate.check_job_tools(names, with_registry(context, ctx))

    defp with_registry(context, ctx), do: Map.put(context, :capability_registry, ctx.registry)

    # What the turn read does not count, as it does not for a sign-in of the
    # turn's own: a turn reads a job's last run before it changes the job, and
    # a Computer History note is in the turn before its first word.
    test "the owner's own turn sets one up, by chat or by voice, whatever it read", ctx do
      for context <- [
            chat(ctx),
            chat(ctx, %{channel: "companion", chat_type: nil}),
            chat(ctx, %{outside_sources: @read}),
            Map.delete(chat(ctx), :outside_sources),
            voice(ctx),
            Map.put(voice(ctx), :outside_sources, @read)
          ] do
        assert :ok = job_check(context, ctx)
      end
    end

    test "a scheduled run sets one up only when its own job names browser", ctx do
      assert :ok = job_check(scheduled(ctx), ctx)
      assert :ok = job_check(Map.put(scheduled(ctx), :outside_sources, @read), ctx)

      for jobs <- [SearchJobs, OpenJobs] do
        assert {:error, text} = job_check(scheduled(ctx, jobs), ctx)
        assert text =~ "signs in to websites with the logins you saved"
        assert text =~ "only when you ask directly, from your own chat, app or voice"
        assert text =~ "can be given allowed tools that leave it out"
        refute text =~ "read nothing from outside"
      end
    end

    # Whose job it is decides, not who asks: an existing job is judged at its
    # own trust (`JobRegistrySupport.check_job_access/2` hands it on).
    test "the owner's job is held from a guest-trust caller, and a guest's job from no one",
         ctx do
      plugin_worker = chat(ctx, %{effective_trust: :guest, skill_depth: 1})

      for caller <- [plugin_worker, chat(ctx, %{source_trust: :guest})] do
        assert {:error, text} =
                 AccessGate.check_job_tools(@job_tools, with_registry(caller, ctx), :operator)

        assert text =~ "signs in to websites with the logins you saved"
      end

      for caller <- [plugin_worker, chat(ctx, %{skill_depth: 1}), chat(ctx)] do
        assert :ok = AccessGate.check_job_tools(@job_tools, with_registry(caller, ctx), :guest)
      end
    end

    test "no other turn without the owner in it sets one up", ctx do
      buzz = %{"BUZZ_RELAY_URL" => "wss://relay.example.test", "PATH" => "/usr/bin"}

      for context <- [
            chat(ctx, %{skill_depth: 1}),
            chat(ctx, %{subagent_depth: 1}),
            ctx |> chat() |> Map.delete(:source_trust) |> Map.put(:effective_trust, :operator),
            Map.put(scheduled(ctx), :trigger, "cue"),
            chat(ctx, %{computer_use_origin: :unattended}),
            chat(ctx, %{harness_continuation_depth: 1}),
            chat(ctx, %{session_env: buzz})
          ] do
        assert {:error, text} = job_check(context, ctx)
        assert text =~ "signs in to websites with the logins you saved"
      end
    end

    test "a guest's job never signs in, so a guest's turn sets one up as before", ctx do
      assert :ok = job_check(chat(ctx, %{source_trust: :guest}), ctx)
      assert :ok = job_check(chat(ctx, %{effective_trust: :guest}), ctx)
    end

    test "a job that names no browser is not this rule's", ctx do
      assert :ok = job_check(chat(ctx, %{skill_depth: 1}), ctx, ["web_search"])
      assert :ok = job_check(scheduled(ctx, OpenJobs), ctx, ["web_search"])
    end
  end

  # The waiting call runs in its own process, as a tool call runs in its turn's.
  defp ask(context, prompt \\ @prompt, timeout_ms \\ Timeouts.sign_in_approval()) do
    Task.async(fn -> AccessGate.ask_in_call(prompt, context, timeout_ms) end)
  end

  defp asked do
    assert_receive {:approval, %{access_sensitive: id}, waiter}
    assert_receive {:reply, {:approval_prompt, text, @token}}
    {id, waiter, text}
  end

  defp result(task), do: Task.await(task, 10_000)

  describe "ask_in_call/3" do
    test "the owner's yes answers the waiting call", ctx do
      context = chat(ctx)
      task = ask(context)
      {id, _waiter, text} = asked()

      assert text ==
               @prompt <> "\n\n" <> AccessGate.approval_line(@token, context, :in_call)

      assert :ok = AccessGate.confirm_in_call(id, ctx.pending)
      assert result(task) == {:ok, :confirmed}

      # Answered once: a second tap finds nothing waiting.
      assert {:error, :not_in_call} = AccessGate.confirm_in_call(id, ctx.pending)
      assert {:error, :not_found} = AccessGate.deny(id, ctx.pending)
    end

    test "the owner's no answers the waiting call", ctx do
      task = ask(chat(ctx))
      {id, _waiter, _text} = asked()

      assert {:ok, :in_call} = AccessGate.deny(id, ctx.pending)
      assert result(task) == {:error, :denied}
      assert {:error, :not_in_call} = AccessGate.confirm_in_call(id, ctx.pending)
    end

    test "no answer in the window ends the wait as unanswered and says which deadline", ctx do
      task = ask(chat(ctx))
      {id, waiter, _text} = asked()

      # The window's expiry, delivered by hand instead of waited for.
      send(waiter, {:access_timeout, id})
      assert result(task) == {:error, :unanswered}

      assert_receive {:telemetry, [:fermix, :timeout, :expired], %{ms: ms}, %{name: name}}
      assert {name, ms} == {:sign_in_approval, Timeouts.sign_in_approval()}

      assert {:error, :not_in_call} = AccessGate.confirm_in_call(id, ctx.pending)
      assert {:error, :not_found} = AccessGate.deny(id, ctx.pending)
    end

    test "the deadline it is given is armed", ctx do
      task = ask(chat(ctx), @prompt, 1)
      {id, _waiter, _text} = asked()

      assert result(task) == {:error, :unanswered}
      assert {:error, :not_in_call} = AccessGate.confirm_in_call(id, ctx.pending)
    end

    test "a deadline past the confirmation window is refused before anything is asked", ctx do
      assert_raise ArgumentError, fn ->
        AccessGate.ask_in_call(@prompt, chat(ctx), Pending.ttl_ms() + 1)
      end

      refute_received {:approval, _, _}
    end

    # `/stop` kills the turn's task through its Task.Supervisor (the Queue's
    # `terminate_child`), and the tool call waits inside that process: nothing
    # of the call runs again, so the store's monitor drops the record and a
    # late answer finds none.
    test "a stopped turn ends the wait, drops the record and answers nothing late", ctx do
      supervisor = start_supervised!(Task.Supervisor)
      test_pid = self()
      context = chat(ctx)

      {:ok, turn} =
        Task.Supervisor.start_child(supervisor, fn ->
          send(test_pid, {:returned, AccessGate.ask_in_call(@prompt, context, 60_000)})
        end)

      {id, ^turn, _text} = asked()
      store = GenServer.whereis(ctx.pending)
      :erlang.trace(store, true, [:receive])

      assert :ok = Task.Supervisor.terminate_child(supervisor, turn)
      refute Process.alive?(turn)
      assert_receive {:trace, ^store, :receive, {:DOWN, _ref, :process, ^turn, :shutdown}}
      :erlang.trace(store, false, [:receive])

      assert %{records: records} = :sys.get_state(store)
      assert records == %{}
      assert {:error, :not_in_call} = AccessGate.confirm_in_call(id, ctx.pending)
      assert {:error, :not_found} = AccessGate.deny(id, ctx.pending)
      refute_received {:returned, _result}
    end

    test "the prompt is one line: control and format characters are escaped", ctx do
      task = ask(chat(ctx), "Sign in to github.com as al\nice\u202E\u200B?")
      {id, _waiter, text} = asked()

      assert [shown, _approval_line] = String.split(text, "\n\n")
      assert shown == "Sign in to github.com as al\\nice\\u{202E}\\u{200B}?"
      refute shown =~ "\n"

      assert {:ok, :in_call} = AccessGate.deny(id, ctx.pending)
      assert result(task) == {:error, :denied}
      assert AccessGate.visible("a\rb\tc") == "a\\rb\\tc"
    end

    test "a turn with no chat approval asks in the owner's own inbox", ctx do
      context = inbox_only(ctx, {:ok, @token, :new})
      task = ask(context)

      assert_receive {:owner_inbox, %{access_sensitive: id, prompt: @prompt, in_call: true}, _w}
      assert :ok = AccessGate.confirm_in_call(id, ctx.pending)
      assert result(task) == {:ok, :confirmed}
    end

    test "an owner inbox that cannot be reached is not delivered and leaves no record", ctx do
      context = inbox_only(ctx, {:error, {:owner_inbox_unreachable, :closed}})

      assert {:error, {:not_delivered, {:owner_inbox_unreachable, :closed}}} =
               result(ask(context))

      assert_receive {:owner_inbox, %{access_sensitive: id}, _waiter}
      assert {:error, :not_in_call} = AccessGate.confirm_in_call(id, ctx.pending)
      assert %{records: records} = :sys.get_state(ctx.pending)
      assert records == %{}
    end

    test "a turn with nowhere to ask, or a voice call, is not delivered", ctx do
      bare = Map.drop(chat(ctx), [:approval_fn, :reply_fn])
      assert {:error, {:not_delivered, :no_surface}} = result(ask(bare))
      assert {:error, {:not_delivered, :voice}} = result(ask(voice(ctx)))

      assert %{records: records} = :sys.get_state(ctx.pending)
      assert records == %{}
    end

    test "a full store is not delivered", ctx do
      for n <- 1..Pending.max_live() do
        assert {:ok, _id, :new} =
                 Pending.park(
                   %{
                     tool: "tesla_unlock_doors",
                     args: %{},
                     digest: "d#{n}",
                     plugin: "tesla",
                     auth_profile: nil,
                     command_ref: nil,
                     binding: {:conversation, {"telegram", "1", :root}},
                     sources: [],
                     snapshot: %{session_id: "other"}
                   },
                   ctx.pending
                 )
      end

      assert {:error, {:not_delivered, :too_many_pending}} = result(ask(chat(ctx)))
      refute_received {:approval, _, _}
    end

    # The parked-call path runs a recorded call; an in-call record has none.
    test "confirm/2 never runs an in-call record", ctx do
      task = ask(chat(ctx))
      {id, _waiter, _text} = asked()

      assert {:error, _text} = AccessGate.confirm(id, ctx.pending)
      assert :ok = AccessGate.confirm_in_call(id, ctx.pending)
      assert result(task) == {:ok, :confirmed}
    end
  end

  describe "Timeouts.sign_in_approval/0" do
    test "is the confirmation window a token and its record live for" do
      assert Timeouts.sign_in_approval() == Pending.ttl_ms()
    end
  end
end
