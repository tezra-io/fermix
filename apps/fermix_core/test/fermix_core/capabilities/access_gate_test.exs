defmodule FermixCore.Capabilities.AccessGateTest do
  # Each test parks in its own `AccessGate.Pending`, handed to the gate through
  # the context (`:access_pending`), so no record ever meets another test's or
  # counts against the application store's bound.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Tools.GetCodingRun
  alias FermixCore.Tools.GetJobRun
  alias FermixCore.Tools.ListJobRuns
  alias FermixCore.Tools.SkillRun
  alias FermixCore.Tools.Telemetry, as: ToolTelemetry

  @token "TOKEN123"

  defmodule AllowlistedJobs do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: ["tesla_unlock_doors"]}}
  end

  defmodule EmptyJobs do
    def get_job(_id, _opts), do: {:ok, %{allowed_tools: []}}
  end

  # The stand-in executor: reports every run to the test and emits the executor's
  # own exec event, as the plugin executors do.
  def run(args, context, test_pid) do
    send(test_pid, {:executed, args, context})
    ToolTelemetry.exec("tesla_unlock_doors", context, true, 0)
    {:ok, %{success: true, output: ~s({"result":true}), error: nil}}
  end

  setup do
    sid = "gate-#{System.unique_integer([:positive])}"
    test_pid = self()
    handler = "access-gate-#{sid}"

    :telemetry.attach(
      handler,
      [:fermix, :tool, :exec],
      fn _event, _measurements, metadata, _config ->
        if metadata[:session_id] == sid, do: send(test_pid, {:tool_exec, metadata})
      end,
      nil
    )

    registry = :"access_gate_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    :ok = CapabilityRegistry.register(registry, flagged())
    pending = :"access_gate_pending_#{System.unique_integer([:positive])}"
    start_supervised!({Pending, name: pending})

    on_exit(fn -> :telemetry.detach(handler) end)
    %{sid: sid, registry: registry, pending: pending}
  end

  defp flagged(metadata \\ %{}) do
    Capability.new(%{
      name: "tesla_unlock_doors",
      description: "Unlock the car's doors.",
      parameters: %{"type" => "object"},
      kind: :mcp,
      executor: {__MODULE__, :run, [self()]},
      policy_class: :external_api,
      metadata:
        Map.merge(
          %{
            access_sensitive?: true,
            plugin_owned?: true,
            plugin: "tesla",
            auth_profile: "tesla:default"
          },
          metadata
        )
    })
  end

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
        capability_registry: ctx.registry,
        access_pending: ctx.pending,
        outside_sources: MapSet.new(),
        reply_fn: fn part -> send(test_pid, {:reply, part}) end,
        approval_fn: fn request ->
          send(test_pid, {:approval, request})
          {:ok, @token, store_answer(request)}
        end
      },
      extra
    )
  end

  # Stands in for the channel confirmations store, which dedupes per origin: the
  # first request for an intent is `:new`, a repeat while its token lives is
  # `:existing`. The gate runs inline, so the test process holds the state.
  defp store_answer(%{access_sensitive: id}) do
    seen = Process.get(:live_tokens, MapSet.new())
    Process.put(:live_tokens, MapSet.put(seen, id))
    if MapSet.member?(seen, id), do: :existing, else: :new
  end

  defp burn_token(id), do: Process.put(:live_tokens, MapSet.delete(Process.get(:live_tokens), id))

  defp tainted(ctx, extra \\ %{}),
    do: chat(ctx, Map.put(extra, :outside_sources, MapSet.new([{:tool, "web_fetch"}])))

  defp voice(ctx, extra \\ %{}) do
    %{
      source_trust: :operator,
      computer_use_origin: :voice,
      session_id: ctx.sid,
      agent_name: "main",
      voice_call_id: "call-#{ctx.sid}",
      capability_registry: ctx.registry,
      access_pending: ctx.pending,
      outside_sources: MapSet.new()
    }
    |> Map.merge(extra)
  end

  defp inbox_only(ctx, extra) do
    test_pid = self()

    chat(ctx, extra)
    |> Map.drop([:approval_fn])
    |> Map.put(:owner_inbox_approval_fn, fn request ->
      send(test_pid, {:owner_inbox, request})
      {:ok, @token, store_answer(request)}
    end)
  end

  # An ACP turn as the gateway builds it (no slash commands, so the owner-inbox
  # closure and no in-chat approval), under a Buzz harness's env or an editor's.
  defp acp(ctx, session_env, extra \\ %{}) do
    inbox_only(
      ctx,
      Map.merge(%{conversation_key: {"acp", ctx.sid, :root}, session_env: session_env}, extra)
    )
  end

  @buzz_env %{"BUZZ_RELAY_URL" => "wss://relay.example.test", "PATH" => "/usr/bin"}
  @zed_env %{"PATH" => "/usr/bin"}

  defp scheduled(ctx, jobs) do
    %{
      source_trust: :operator,
      session_id: ctx.sid,
      conversation_key: {:scheduled_job, "job_x", "run_1"},
      job_id: "job_x",
      jobs_registry: jobs,
      memory_repo: :unused,
      capability_registry: ctx.registry,
      access_pending: ctx.pending,
      outside_sources: MapSet.new([{:tool, "web_fetch"}])
    }
  end

  @args %{"vin" => "5YJ3E1EA"}

  defp execute(context), do: Capability.execute(flagged(), @args, context)

  defp held_text({:ok, %{success: false, error: text}}), do: text

  describe "admit/3 leaves every other tool alone" do
    test "a capability without the flag dispatches without reading the context" do
      plain = %{flagged() | metadata: %{plugin_owned?: true, plugin: "tesla"}}
      assert {:dispatch, %{}} = AccessGate.admit(plain, @args, %{})
    end
  end

  describe "a direct request is the consent" do
    test "a clean attended owner turn dispatches at once, labelled direct", ctx do
      assert {:ok, %{success: true}} = execute(chat(ctx))
      assert_received {:executed, @args, %{access_gate: "direct"}}
      assert_received {:tool_exec, %{access_gate: "direct", success: true}}
      refute_received {:reply, _}
    end

    test "a clean voice turn dispatches at once", ctx do
      assert {:ok, %{success: true}} = execute(voice(ctx))
      assert_received {:executed, @args, _context}
    end

    test "the target plugin's own reads keep the turn clean", ctx do
      context = chat(ctx, %{outside_sources: MapSet.new([{:plugin, "tesla"}])})
      assert {:ok, %{success: true}} = execute(context)
      assert_received {:executed, @args, _context}
    end
  end

  describe "a turn that read outside content" do
    test "web, another plugin, an operator MCP tool, a worker's report or a job's results each hold for this chat",
         ctx do
      sources = [
        {:tool, "web_fetch"},
        {:plugin, "agentmail"},
        {:tool, "notes_search"},
        {:tool, "subagents"},
        UntrustedContent.outside_source(Builtin.from_tool_module(SkillRun)),
        UntrustedContent.outside_source(Builtin.from_tool_module(GetCodingRun)),
        UntrustedContent.outside_source(Builtin.from_tool_module(GetJobRun)),
        UntrustedContent.outside_source(Builtin.from_tool_module(ListJobRuns))
      ]

      for source <- sources do
        sid = "#{ctx.sid}-#{elem(source, 1)}"
        context = chat(%{ctx | sid: sid}, %{outside_sources: MapSet.new([source])})

        result = execute(context)
        text = held_text(result)

        refute_received {:executed, _, _}
        assert_received {:approval, %{access_sensitive: id}} when is_binary(id)
        assert_received {:reply, {:approval_prompt, prompt, @token}}
        assert prompt =~ "tesla_unlock_doors"
        assert prompt =~ "/confirm #{@token}"
        assert text =~ "Not sent"
        refute text =~ @token
      end
    end

    test "the held call emits one exec event proving it never ran", ctx do
      held_text(execute(tainted(ctx)))

      assert_received {:tool_exec, metadata}
      assert metadata.tool == "tesla_unlock_doors"
      assert metadata.success == false
      assert metadata.access_gate == "held_this_chat"
      assert is_binary(metadata.access_intent)

      assert metadata.policy_enforcement == %{
               source: "access_gate",
               decision: "confirm",
               phase: "pre_execution"
             }

      refute_received {:tool_exec, _}
    end

    # Nothing resumes here: the daemon itself runs the confirmed command, so the
    # prompt must not promise the owner a resumed request.
    test "the owner's prompt says Fermix runs the command once they confirm", ctx do
      held_text(execute(tainted(ctx)))

      assert_received {:reply, {:approval_prompt, prompt, @token}}
      assert prompt =~ "Fermix runs exactly this command"
      refute prompt =~ "resume"
    end

    test "an attended context with no outside_sources key holds (fail closed)", ctx do
      context = Map.delete(chat(ctx), :outside_sources)
      assert held_text(execute(context)) =~ "Not sent"
      refute_received {:executed, _, _}
    end

    test "a second identical call sends no second prompt", ctx do
      context = tainted(ctx)
      first = held_text(execute(context))
      second = held_text(execute(context))

      assert first =~ "Not sent"
      assert second =~ "already waiting"
      assert_received {:reply, {:approval_prompt, _prompt, @token}}
      refute_received {:reply, _}
    end

    # `/deny` (or expiry) burns the owner's token; the same call asked again gets
    # a fresh prompt against the same parked record.
    test "after the owner's token is gone the same call prompts afresh", ctx do
      context = tainted(ctx)
      held_text(execute(context))
      assert_received {:approval, %{access_sensitive: id}}
      assert_received {:reply, {:approval_prompt, _prompt, @token}}

      burn_token(id)
      assert held_text(execute(context)) =~ "A confirmation is now in this chat"
      assert_received {:approval, %{access_sensitive: ^id}}
      assert_received {:reply, {:approval_prompt, _prompt, @token}}
    end

    test "an owner-inbox surface gets the prompt when there is no in-chat approval", ctx do
      context = inbox_only(ctx, %{outside_sources: MapSet.new([{:tool, "web_fetch"}])})
      text = held_text(execute(context))

      assert_received {:owner_inbox, %{access_sensitive: id, prompt: prompt}} when is_binary(id)
      assert prompt =~ "tesla_unlock_doors"
      assert text =~ "own chat"
      refute text =~ @token
      refute_received {:executed, _, _}
    end

    test "an owner-inbox surface dispatches a clean request at once", ctx do
      assert {:ok, %{success: true}} = execute(inbox_only(ctx, %{}))
      assert_received {:executed, @args, _context}
    end

    test "an owner inbox that cannot be reached refuses and drops the record", ctx do
      context =
        inbox_only(ctx, %{outside_sources: MapSet.new([{:tool, "web_fetch"}])})
        |> Map.put(:owner_inbox_approval_fn, fn _request -> {:error, :no_owner_inbox} end)

      text = held_text(execute(context))
      assert text =~ "Fermix app"
      assert_received {:tool_exec, %{access_gate: "refused_no_surface"}}

      # Nothing is left parked: the same call parks afresh next time.
      assert {:ok, _id, :new} =
               Pending.park(
                 %{
                   binding: {:conversation, context.conversation_key},
                   digest: AccessGate.digest("tesla_unlock_doors", @args)
                 },
                 ctx.pending
               )
    end

    test "a voice call routes to a spoken yes before any approval closure", ctx do
      context = Map.merge(tainted(ctx), %{voice_call_id: "call-#{ctx.sid}"})
      text = held_text(execute(context))

      assert text =~ "say yes"
      refute_received {:approval, _}
      refute_received {:reply, _}
      assert {:ok, _id} = Pending.voice_pending("call-#{ctx.sid}", ctx.pending)
    end

    test "with no surface at all the call is refused and names where to ask", ctx do
      context = tainted(ctx) |> Map.drop([:approval_fn])
      text = held_text(execute(context))

      assert text =~ "Fermix app"
      assert text =~ "own chat"
      assert text =~ "voice"
      assert_received {:tool_exec, %{access_gate: "refused_no_surface"}}
    end
  end

  # A Buzz-wired ACP session is a channel other people can post in, so a request
  # there is not proof the owner asked (owner decision, MOB-1): even a clean one
  # waits for the owner in their own chat, never in the Buzz channel.
  describe "a shared Buzz channel" do
    test "holds for the owner's own chat even when the turn read nothing", ctx do
      text = held_text(execute(acp(ctx, @buzz_env)))

      assert_received {:owner_inbox, %{access_sensitive: id, prompt: prompt}} when is_binary(id)
      assert prompt =~ "tesla_unlock_doors"
      assert prompt =~ "shared Buzz channel"
      assert text =~ "Buzz channel"
      assert text =~ "own chat"
      refute text =~ @token
      refute_received {:executed, _, _}
      refute_received {:reply, _}
      assert_received {:tool_exec, %{access_gate: "held_owner_inbox"}}
    end

    test "names both reasons when the Buzz turn also read outside content", ctx do
      held_text(
        execute(acp(ctx, @buzz_env, %{outside_sources: MapSet.new([{:tool, "web_fetch"}])}))
      )

      assert_received {:owner_inbox, %{prompt: prompt}}
      assert prompt =~ "shared Buzz channel"
      assert prompt =~ "web_fetch"
    end

    test "the owner's confirmation runs the request once, with no re-ask in Buzz", ctx do
      held_text(execute(acp(ctx, @buzz_env)))
      assert_received {:owner_inbox, %{access_sensitive: id}}

      assert {:ok, _outcome} = AccessGate.confirm(id, ctx.pending)
      assert_received {:executed, @args, %{access_gate: "confirmed", access_intent: ^id}}
    end

    test "with no owner chat to reach it is refused, naming the app, own chat and voice", ctx do
      context =
        acp(ctx, @buzz_env)
        |> Map.put(:owner_inbox_approval_fn, fn _request -> {:error, :no_owner_inbox} end)

      text = held_text(execute(context))
      assert text =~ "Fermix app"
      assert text =~ "own chat"
      assert text =~ "voice"
      refute_received {:executed, _, _}
    end

    test "an editor session without a relay runs a clean request at once", ctx do
      assert {:ok, %{success: true}} = execute(acp(ctx, @zed_env))
      assert_received {:executed, @args, %{access_gate: "direct"}}
      refute_received {:owner_inbox, _}
    end

    test "an editor session without a relay holds a tainted request for the owner's chat", ctx do
      held_text(
        execute(acp(ctx, @zed_env, %{outside_sources: MapSet.new([{:tool, "web_fetch"}])}))
      )

      assert_received {:owner_inbox, %{prompt: prompt}}
      assert prompt =~ "web_fetch"
      refute prompt =~ "Buzz"
      refute_received {:executed, _, _}
    end
  end

  # The turn that read the outside content must not be able to answer the
  # owner's prompt itself (a click on the app card, the Telegram button, a
  # played "yes"), so while its parked call waits it may run nothing else.
  describe "while a call the turn parked waits on the owner" do
    defp plain do
      Capability.new(%{
        name: "computer_use",
        description: "Drive the desktop.",
        parameters: %{"type" => "object"},
        kind: :builtin,
        executor: {__MODULE__, :run, [self()]},
        policy_class: :gui_control
      })
    end

    test "the turn that parked it is waiting, and a turn that parked nothing is not", ctx do
      context = tainted(ctx)
      refute AccessGate.waiting?(context)

      held_text(execute(context))
      assert AccessGate.waiting?(context)
      refute AccessGate.waiting?(chat(%{ctx | sid: "#{ctx.sid}-other"}))

      # A Live delegation's turn parks on the call, and is waiting the same way.
      spoken =
        voice(%{ctx | sid: "#{ctx.sid}-voice"}, %{outside_sources: context.outside_sources})

      held_text(execute(spoken))
      assert AccessGate.waiting?(spoken)
    end

    test "every other call from that turn is refused, with one exec event proving it", ctx do
      context = Map.put(tainted(ctx), :access_waiting, true)

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(plain(), %{"action" => "click"}, context)

      assert text =~ "already waiting"
      refute_received {:executed, _, _}

      assert_received {:tool_exec, metadata}
      assert metadata.tool == "computer_use"
      assert metadata.access_gate == "refused_waiting"
      assert metadata.policy_enforcement.decision == "deny"
      refute_received {:tool_exec, _}
    end

    # The held result itself says a call now waits, so a caller running more
    # calls in the same step (the agent loop's batch) stops at once, and so does
    # a turn that re-asked about a record another turn of the chat parked.
    test "a parked call's result says it waits on the owner, on every surface", ctx do
      assert {:ok, %{access_waiting: true}} = execute(tainted(ctx))

      reask =
        tainted(%{ctx | sid: "#{ctx.sid}-reask"}, %{
          conversation_key: {"telegram", ctx.sid, :root}
        })

      assert {:ok, %{access_waiting: true, error: text}} = execute(reask)
      assert text =~ "already waiting"

      inbox =
        inbox_only(%{ctx | sid: "#{ctx.sid}-inbox"}, %{outside_sources: reask.outside_sources})

      assert {:ok, %{access_waiting: true}} = execute(inbox)

      spoken =
        Map.put(tainted(%{ctx | sid: "#{ctx.sid}-voice"}), :voice_call_id, "call-#{ctx.sid}")

      assert {:ok, %{access_waiting: true}} = execute(spoken)
    end

    test "a refused, dispatched or already-waiting call's result does not say so", ctx do
      for context <- [
            chat(ctx, %{subagent_depth: 1}),
            chat(ctx),
            Map.put(tainted(ctx), :access_waiting, true)
          ] do
        assert {:ok, result} = execute(context)
        refute Map.has_key?(result, :access_waiting)
      end
    end

    test "once the owner confirms, nothing of that turn is waiting any more", ctx do
      context = tainted(ctx)
      held_text(execute(context))
      assert_received {:approval, %{access_sensitive: id}}

      assert {:ok, _outcome} = AccessGate.confirm(id, ctx.pending)
      refute AccessGate.waiting?(context)
    end
  end

  describe "who may never run it" do
    test "delegated and skill workers are refused even when clean", ctx do
      for extra <- [%{subagent_depth: 1}, %{skill_depth: 1}] do
        assert held_text(execute(chat(ctx, extra))) =~ "delegated worker"
      end

      refute_received {:executed, _, _}
    end

    test "a worker inside a scheduled run is refused", ctx do
      context = Map.put(scheduled(ctx, AllowlistedJobs), :subagent_depth, 1)
      assert held_text(execute(context)) =~ "delegated worker"
    end

    test "background, daemon-started, detached, continuation, guest and trust-less turns are refused",
         ctx do
      contexts = [
        chat(ctx, %{computer_use_origin: :unattended}),
        chat(ctx, %{harness_continuation_depth: 1}),
        chat(ctx, %{source_trust: :guest}),
        Map.delete(chat(ctx), :source_trust),
        Map.delete(chat(ctx), :computer_use_origin)
      ]

      for context <- contexts do
        assert held_text(execute(context)) =~ "asks directly"
      end

      refute_received {:executed, _, _}
    end
  end

  describe "scheduled jobs" do
    test "a job whose row names the tool dispatches even though the run read outside content",
         ctx do
      assert {:ok, %{success: true}} = execute(scheduled(ctx, AllowlistedJobs))
      assert_received {:executed, @args, %{access_gate: "scheduled"}}
    end

    test "a job with an empty allowlist is refused", ctx do
      assert held_text(execute(scheduled(ctx, EmptyJobs))) =~ "does not name"
      assert_received {:tool_exec, %{access_gate: "refused_not_allowlisted"}}
    end
  end

  describe "confirm/1" do
    test "runs the recorded call exactly once with the recorded arguments", ctx do
      held_text(execute(tainted(ctx)))
      assert_received {:approval, %{access_sensitive: id}}

      assert {:ok, outcome} = AccessGate.confirm(id, ctx.pending)
      assert outcome =~ "tesla_unlock_doors"
      assert_received {:executed, @args, %{access_gate: "confirmed", access_intent: ^id}}
      assert_received {:tool_exec, %{access_gate: "confirmed", access_intent: ^id}}

      assert {:error, _reason} = AccessGate.confirm(id, ctx.pending)
      refute_received {:executed, _, _}
    end

    test "a later identical call learns it already ran", ctx do
      context = tainted(ctx)
      held_text(execute(context))
      assert_received {:approval, %{access_sensitive: id}}
      assert {:ok, _outcome} = AccessGate.confirm(id, ctx.pending)
      assert_received {:executed, _, _}

      assert held_text(execute(context)) =~ "Already done"
      refute_received {:executed, _, _}
    end

    test "refuses when the capability lost its flag or changed auth profile", ctx do
      for changed <- [%{access_sensitive?: false}, %{auth_profile: "tesla:other"}] do
        sid = "#{ctx.sid}-#{map_size(changed)}-#{System.unique_integer([:positive])}"
        held_text(execute(tainted(%{ctx | sid: sid})))
        assert_received {:approval, %{access_sensitive: id}}

        :ok = CapabilityRegistry.unregister(ctx.registry, "tesla_unlock_doors")
        :ok = CapabilityRegistry.register(ctx.registry, flagged(changed))

        assert {:error, reason} = AccessGate.confirm(id, ctx.pending)
        assert reason =~ "changed"
        refute_received {:executed, _, _}

        :ok = CapabilityRegistry.unregister(ctx.registry, "tesla_unlock_doors")
        :ok = CapabilityRegistry.register(ctx.registry, flagged())
      end
    end

    test "a confirmation for different arguments is refused", ctx do
      context =
        chat(ctx, %{
          access_confirmed: AccessGate.digest("tesla_unlock_doors", %{"vin" => "OTHER"}),
          access_intent: "intent-x"
        })

      assert held_text(execute(context)) =~ "does not match"
      assert_received {:tool_exec, %{access_gate: "refused_confirm_mismatch"}}
      refute_received {:executed, _, _}
    end
  end

  describe "spoken answers" do
    test "affirmative? accepts a whole-utterance yes and nothing else" do
      for yes <- ["Yes.", "yes", "  Go ahead!", "Yes, please.", "do it", "Confirmed"] do
        assert AccessGate.affirmative?(yes), yes
      end

      for other <- [
            "yes, but first check the tires",
            "say yes to confirm",
            "no",
            "",
            "not yet",
            "yes no"
          ] do
        refute AccessGate.affirmative?(other), other
      end
    end

    test "answer_spoken confirms a yes and discards anything else", ctx do
      context = Map.merge(tainted(ctx), %{voice_call_id: "call-#{ctx.sid}"})
      held_text(execute(context))
      assert {:ok, id} = Pending.voice_pending("call-#{ctx.sid}", ctx.pending)

      assert :declined = AccessGate.answer_spoken(id, "what's the weather", ctx.pending)
      assert :none = Pending.voice_pending("call-#{ctx.sid}", ctx.pending)

      held_text(execute(context))
      assert {:ok, id} = Pending.voice_pending("call-#{ctx.sid}", ctx.pending)
      assert {:confirmed, ^id} = AccessGate.answer_spoken(id, "Yes.", ctx.pending)
    end
  end

  describe "check_job_tools/2" do
    test "a flagged tool is refused from a tainted or worker turn and allowed from a clean one",
         ctx do
      names = ["web_fetch", "tesla_unlock_doors"]

      assert {:error, text} = AccessGate.check_job_tools(names, tainted(ctx))
      assert text =~ "tesla_unlock_doors"
      assert {:error, _text} = AccessGate.check_job_tools(names, chat(ctx, %{subagent_depth: 1}))
      assert :ok = AccessGate.check_job_tools(names, chat(ctx))
    end

    test "a flagged tool is refused from a Buzz channel and allowed from a clean editor session",
         ctx do
      names = ["tesla_unlock_doors"]

      assert {:error, text} = AccessGate.check_job_tools(names, acp(ctx, @buzz_env))
      assert text =~ "tesla_unlock_doors"
      assert :ok = AccessGate.check_job_tools(names, acp(ctx, @zed_env))
    end

    test "names without the flag pass from any turn", ctx do
      assert :ok = AccessGate.check_job_tools(["web_fetch", "unknown_tool"], tainted(ctx))
    end
  end
end
