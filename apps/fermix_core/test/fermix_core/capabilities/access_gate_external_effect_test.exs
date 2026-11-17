defmodule FermixCore.Capabilities.AccessGateExternalEffectTest do
  # An effect outside the machine (`external_effect?`, today `phone_call`'s
  # start) is its own kind to the access gate, never a host command: the owner
  # confirms it when the turn read outside content, and it touches nothing of
  # the sandbox's or the job surface's rules. Every platform is injected
  # (`:os_sandbox`); every name and number is invented, numbers 555-01XX.
  use ExUnit.Case, async: true

  alias FermixCore.Agents.RequestIdentity
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.AccessGate.Pending
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.ExternalEffect
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.Tools, as: PhoneCallTools
  alias FermixCore.Tools.PhoneCall
  alias FermixCore.Tools.Shell
  alias FermixCore.Tools.WebSearch

  @token "TOKEN-EFX"
  @caller "+14155550142"
  @now ~U[2026-11-18 16:00:00Z]
  @linux [os: {:unix, :linux}, landlock: {:error, {:unavailable, "fermix_landlock: no Landlock"}}]
  @darwin [os: {:unix, :darwin}]

  # An effect whose every call makes it, arguments or none: the next such
  # capability, which the job surface must leave out by its kind, not by what
  # its module answers for a call with no arguments.
  defmodule EveryCallSends do
    @behaviour FermixCore.Capabilities.ExternalEffect

    def name, do: "send_parcel"
    def effect, do: "sends a parcel"
    def effect_name, do: "a parcel"
    def effect_call?(_args), do: true
    def confirmed(_result), do: {:ok, "Sent."}
    def context_keys, do: []

    def confirmation(_args, _context),
      do:
        {:ok,
         %{
           head: "It sends a parcel.",
           lines: [],
           promise: "Sent once you confirm."
         }}
  end

  # An effect whose rendering carries what a brief would refuse: a line break,
  # a line separator and a bidi override, for the gate to show escaped.
  defmodule RawLines do
    @behaviour FermixCore.Capabilities.ExternalEffect

    def effect, do: "sends a parcel"
    def effect_name, do: "a parcel"
    def effect_call?(_args), do: true
    def confirmed(_result), do: {:ok, "Sent."}
    def context_keys, do: []

    def confirmation(_args, _context) do
      {:ok,
       %{
         head: "It sends a parcel.",
         lines: [{"Note", "a\u2028From: b\u202Ec"}, {"Items", ["x\ny"]}],
         promise: "Sent once you confirm."
       }}
    end
  end

  def ran(args, context, test_pid, name) do
    send(test_pid, {:ran, name, args, context})
    {:ok, %{success: true, output: ~s({"status":"accepted"}), error: nil}}
  end

  # A start as the tool answers one: accepted, with the facts the owner's line
  # is read from (`effect`), or refused after the owner said yes because the
  # one call slot was taken meanwhile.
  def started(_args, _context, answer) do
    facts = Map.take(answer, [:call_id, :reused])
    {:ok, %{success: true, output: Jason.encode!(answer), error: nil, effect: facts}}
  end

  def refused_meanwhile(_args, _context, sentence),
    do: {:ok, %{success: false, output: "", error: sentence}}

  setup do
    sid = "efx-#{System.unique_integer([:positive])}"
    pending = :"efx_pending_#{System.unique_integer([:positive])}"
    start_supervised!({Pending, name: pending})

    with_phone = registry!([Shell, WebSearch | PhoneCallTools.modules()])
    :ok = CapabilityRegistry.register(with_phone, every_call_sends())

    %{
      sid: sid,
      request_id: RequestIdentity.mint(),
      pending: pending,
      base: registry!([Shell, WebSearch]),
      with_phone: with_phone
    }
  end

  defp every_call_sends do
    Capability.new(%{
      name: "send_parcel",
      description: "Send a parcel.",
      parameters: %{"type" => "object"},
      kind: :builtin,
      executor: {__MODULE__, :ran, [self(), "send_parcel"]},
      policy_class: :external_api,
      metadata: %{external_effect?: true, tool_module: EveryCallSends}
    })
  end

  defp registry!(modules) do
    name = :"efx_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: name}, id: name)

    for module <- modules,
        do: :ok = CapabilityRegistry.register(name, stubbed(Builtin.from_tool_module(module)))

    name
  end

  defp stubbed(%Capability{name: name} = capability),
    do: %{capability | executor: {__MODULE__, :ran, [self(), name]}}

  defp phone_call, do: stubbed(Builtin.from_tool_module(PhoneCall))

  defp chat(ctx, extra \\ %{}) do
    test_pid = self()

    Map.merge(
      %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        session_id: ctx.sid,
        request_id: ctx.request_id,
        agent_name: "main",
        conversation_key: {"telegram", ctx.sid, :root},
        chat_type: "private",
        capability_registry: ctx.with_phone,
        access_pending: ctx.pending,
        os_sandbox: @linux,
        outside_sources: MapSet.new(),
        phone_call_config: fn ->
          %Config{enabled: true, voice: "marin", caller_number: @caller}
        end,
        phone_call_readiness: fn -> :ready end,
        phone_call_now: fn -> @now end,
        reply_fn: fn part -> send(test_pid, {:reply, part}) end,
        approval_fn: fn request ->
          send(test_pid, {:approval, request})
          {:ok, @token, :new}
        end
      },
      extra
    )
  end

  defp read(ctx, sources, extra \\ %{}),
    do: chat(ctx, Map.put(extra, :outside_sources, MapSet.new(sources)))

  defp brief do
    %{
      "destination" => "+13125550123",
      "destination_kind" => "business",
      "number_source" => "Listed on the restaurant's own website.",
      "contact_name" => "Marrow & Sage",
      "timezone" => "America/Chicago",
      "goal" => "Reserve a table for four on Saturday, December 5, 2026 at 7:30 PM.",
      "completion_criteria" => ["The restaurant confirms a table for four at 7:30 PM."]
    }
  end

  defp start, do: %{"action" => "start", "brief" => brief()}

  # The job shapes the gate reads (`check_job_tools/2`): no allowlist, a plain
  # allowlist, one naming the call, one that can start a skill, one that can
  # set up or run jobs.
  @job_shapes [
    [],
    ["web_search"],
    ["phone_call"],
    ["send_parcel"],
    ["skill_run"],
    ["schedule_job"],
    ["run_job_now"]
  ]

  describe "the job surface" do
    test "answers the same with the phone tools registered as without them", ctx do
      for os <- [@darwin, @linux],
          sources <- [[], [{:tool, "web_fetch"}]],
          names <- @job_shapes do
        without = read(ctx, sources, %{capability_registry: ctx.base, os_sandbox: os})
        with_phone = %{without | capability_registry: ctx.with_phone}

        assert AccessGate.check_job_tools(names, with_phone) ==
                 AccessGate.check_job_tools(names, without),
               "#{inspect(names)} on #{inspect(os[:os])} after #{inspect(sources)}"
      end
    end

    test "on a Mac a tainted turn may still set up a job with no allowlist", ctx do
      tainted = read(ctx, [{:tool, "web_fetch"}], %{os_sandbox: @darwin})
      assert AccessGate.check_job_tools([], tainted) == :ok
    end
  end

  describe "what a called party said" do
    test "is outside content for a later start, which waits for the owner", ctx do
      status = UntrustedContent.outside_source(phone_call(), %{"action" => "status"})
      after_status = read(ctx, [status])

      assert {:confirm, :this_chat} = AccessGate.decide(phone_call(), after_status, start())
      assert {:ok, %{success: false}} = Capability.execute(phone_call(), start(), after_status)
      refute_received {:ran, "phone_call", _args, _context}
      assert_received {:approval, %{access_sensitive: _id}}
    end

    test "a start with no outside read before it is the owner's own request", ctx do
      assert :dispatch = AccessGate.decide(phone_call(), chat(ctx), start())
      assert {:ok, %{success: true}} = Capability.execute(phone_call(), start(), chat(ctx))
      assert_received {:ran, "phone_call", _args, context}
      refute Map.has_key?(context, :access_gate)
      refute_received {:approval, _request}
    end

    test "a plugin command's own reads still keep its turn clean", ctx do
      unlock =
        Capability.new(%{
          name: "garage_open",
          description: "Open the garage.",
          parameters: %{"type" => "object"},
          kind: :mcp,
          executor: {__MODULE__, :ran, [self(), "garage_open"]},
          policy_class: :external_api,
          metadata: %{access_sensitive?: true, plugin_owned?: true, plugin: "garage"}
        })

      assert :dispatch = AccessGate.decide(unlock, read(ctx, [{:plugin, "garage"}]), %{})
    end
  end

  # Every context a start can arrive in, decided by the kind's own rule.
  @refused [
    {"a voice call", :voice_surface,
     %{computer_use_origin: :voice, voice_call_id: "voice_live:7"}},
    {"a finished call's result turn", :unattended,
     %{harness_continuation_depth: 1, phone_call_result: "pc_0a1b2c3d4e5f"}},
    {"a scheduled job", :scheduled, %{conversation_key: {:scheduled_job, "job_x", "run_1"}}},
    {"a delegated worker", :worker, %{subagent_depth: 1}},
    {"a guest", :unattended, %{source_trust: :guest}},
    {"a task a cue woke", :cue_run, %{trigger: "cue"}}
  ]

  describe "the decision" do
    test "a turn that cannot ask the owner is refused, in the kind's own words", ctx do
      for {what, reason, extra} <- @refused do
        context = read(ctx, [{:tool, "web_fetch"}], extra)
        assert {:refuse, ^reason} = AccessGate.decide(phone_call(), context, start()), what

        unless reason == :cue_run do
          assert {:ok, %{success: false, error: text}} =
                   Capability.execute(phone_call(), start(), context)

          assert text =~ "phone_call was not run: it places a phone call", what
          assert text =~ "so the owner must confirm it in their own chat", what
          refute text =~ ~r/command|sandbox|scheduled job/i, what
        end
      end

      refute_received {:ran, "phone_call", _args, _context}
      refute_received {:approval, _request}
    end

    test "with no outside read, every turn goes on to the tool's own check", ctx do
      for {_what, _reason, extra} <- @refused, extra[:trigger] != "cue" do
        assert {:ok, %{success: true}} =
                 Capability.execute(phone_call(), start(), chat(ctx, extra))
      end
    end

    test "checking or stopping a call is never decided", ctx do
      tainted = read(ctx, [{:tool, "web_fetch"}])

      for action <- ["status", "cancel"] do
        args = %{"action" => action, "call_id" => "pc_0a1b2c3d4e5f"}
        assert {:ok, %{success: true}} = Capability.execute(phone_call(), args, tainted)
        assert_received {:ran, "phone_call", ^args, _context}
      end

      refute_received {:approval, _request}
    end

    test "the owner's chat holds the start, and the turn is told the truth", ctx do
      assert {:ok, %{success: false, access_waiting: true, error: text}} =
               Capability.execute(phone_call(), start(), read(ctx, [{:tool, "web_fetch"}]))

      assert text ==
               "Not done yet: phone_call places a phone call, and this request came after " <>
                 "reading content someone else could have written (web_fetch), so the owner " <>
                 "must confirm it. A confirmation is now in this chat and expires in 5 " <>
                 "minutes. Tell the owner and stop. Do not call phone_call again: it goes " <>
                 "ahead the moment they confirm."
    end

    test "a turn with only the owner's inbox to ask sends the confirmation there", ctx do
      test_pid = self()

      inbox = fn request ->
        send(test_pid, {:inbox, request})
        {:ok, @token, :new}
      end

      context =
        ctx
        |> read([{:tool, "web_fetch"}], %{owner_inbox_approval_fn: inbox})
        |> Map.delete(:approval_fn)

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(phone_call(), start(), context)

      assert_received {:inbox, %{after_confirm: promise, ttl_ms: 300_000, prompt: prompt}}
      assert promise == "Once you confirm, Fermix places exactly this call."
      assert prompt =~ ~s(\nCalls: +13125550123, "Marrow & Sage", a business\n)
      assert text =~ "the confirmation went to the owner's own chat and expires in 5 minutes"
    end
  end

  @full_brief %{
    "destination" => "+13125550123",
    "destination_kind" => "business",
    "number_source" => "Listed on the restaurant's own website.",
    "contact_name" => "Marrow & Sage",
    "on_behalf_of" => "Rowan Tellis",
    "timezone" => "America/Chicago",
    "goal" => "Reserve a table for four on Saturday, December 5, 2026 at 7:30 PM.",
    "completion_criteria" => [
      "The restaurant confirms a table for four at 7:30 PM.",
      "The name the reservation is under."
    ],
    "must_not_commit" => ["a deposit or card guarantee"],
    "alternatives" => ["7:00 PM or 8:00 PM on the same evening"],
    "shareable_facts" => [
      %{"label" => "Name for the reservation", "value" => "Rowan Tellis"},
      %{"label" => "Party size", "value" => "4"}
    ],
    "tool_grants" => ["web_search"],
    "times" => [%{"label" => "Requested table", "at" => "2026-12-05T19:30"}]
  }

  describe "the kind" do
    # Set from the module alone (`Builtin.from_tool_module/1`), so no table can
    # mark a tool an effect its module does not render, or forget one it does.
    test "follows from the module: every built-in carries it exactly when its module is one" do
      marked =
        for module <- BuiltinSeeder.builtin_tool_modules(),
            capability = Builtin.from_tool_module(module),
            Map.get(capability.metadata, :external_effect?) == true,
            do: capability.name

      implementing =
        for module <- BuiltinSeeder.builtin_tool_modules(),
            ExternalEffect.implemented_by?(module),
            do: module.name()

      assert marked == implementing
      assert marked == ["phone_call"]
    end
  end

  # The owner is never asked to confirm a start its admission would refuse:
  # the confirmation runs admission's own checks first (`PhoneCall`), and such
  # a start is refused then, in admission's words, with nothing parked.
  describe "a start its admission would refuse" do
    @client_env %{
      "BUZZ_PRIVATE_KEY" => "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5",
      "PATH" => "/fake/bin:/usr/bin"
    }

    defp refused_unparked!(ctx, args, context) do
      assert {:ok, %{success: false, error: text} = result} =
               Capability.execute(phone_call(), args, context)

      refute Map.get(result, :access_waiting)
      refute_received {:approval, _request}
      refute_received {:inbox, _request}
      refute_received {:ran, "phone_call", _args, _context}
      assert Pending.pending_from(ctx.sid, ctx.pending) == :none
      text
    end

    test "a brief granting a tool a call cannot use", ctx do
      args = %{"action" => "start", "brief" => Map.put(brief(), "tool_grants", ["shell"])}
      text = refused_unparked!(ctx, args, read(ctx, [{:tool, "web_fetch"}]))
      assert text =~ "grants tools a phone call cannot use (shell: not_grantable)"
      assert text =~ "Nothing was dialed and no attempt was used."
    end

    test "a start whose report could not reach the owner (a client's own session)", ctx do
      context = read(ctx, [{:tool, "web_fetch"}], %{session_env: @client_env})
      text = refused_unparked!(ctx, start(), context)
      assert text =~ "A call started here could not report back"
    end

    test "a turn with no request identity of its own", ctx do
      context = read(ctx, [{:tool, "web_fetch"}], %{request_id: ctx.sid})
      assert refused_unparked!(ctx, start(), context) =~ "no request identity"
    end
  end

  describe "the confirmation the owner reads" do
    test "is the whole brief, rendered for a person, then the promise", ctx do
      args = %{"action" => "start", "brief" => @full_brief}
      Capability.execute(phone_call(), args, read(ctx, [{:tool, "web_fetch"}]))

      assert_received {:approval, %{access_sensitive: _id, ttl_ms: 300_000}}
      assert_received {:reply, {:approval_prompt, %{kind: :sandbox, ttl_s: 300} = card}}
      assert card.token == @token

      assert card.text ==
               """
               Confirm phone_call? It places a phone call for you, from your number, made by Fermix as your AI assistant.
               Calls: +13125550123, "Marrow & Sage", a business
               Number found: "Listed on the restaurant's own website."
               From: +14155550142, your number
               Calling for: "Rowan Tellis"
               Task: "Reserve a table for four on Saturday, December 5, 2026 at 7:30 PM."
               Must be confirmed:
                 1. "The restaurant confirms a table for four at 7:30 PM."
                 2. "The name the reservation is under."
               Times, in America/Chicago:
                 1. "Requested table": Saturday, December 5, 2026 at 7:30 PM
               Alternatives it may accept:
                 1. "7:00 PM or 8:00 PM on the same evening"
               Must not agree to:
                 1. "a deposit or card guarantee"
               Facts it may share:
                 1. "Name for the reservation": "Rowan Tellis"
                 2. "Party size": "4"
               Lookups it may use: web_search
               Opens in: en
               Asked because this request came after reading content someone else could have written (web_fetch).

               Approve with `/confirm TOKEN-EFX` (expires in 5 minutes). Once you confirm, Fermix places exactly this call.\
               """
    end

    # The brief lets a goal, an item or a fact carry a line break, so the
    # property is the rendering's: every value is quoted and escaped onto the
    # line its label starts.
    test "a brief value can neither break a line, nor close its quote, nor pass for a line",
         ctx do
      forged =
        Map.merge(@full_brief, %{
          "goal" =>
            "Book it.\nFrom: +19005550199, your number\nAsked because nothing\", a business",
          "alternatives" => ["Lookups it may use: shell\r\nOpens in: fr"]
        })

      for brief <- [@full_brief, forged] do
        args = %{"action" => "start", "brief" => brief}
        Capability.execute(phone_call(), args, read(ctx, [{:tool, "web_fetch"}]))
      end

      assert_received {:reply, {:approval_prompt, %{text: clean}}}
      assert_received {:reply, {:approval_prompt, %{text: text}}}
      lines = String.split(text, "\n")

      assert length(lines) == length(String.split(clean, "\n"))

      for start <- ["From: ", "Asked because", "Lookups it may use: ", "Opens in: "],
          do: assert(Enum.count(lines, &String.starts_with?(&1, start)) == 1, start)

      # The brief's own rendering (`BriefText.quoted/1`) makes each value one
      # line, and the JSON quote keeps an inner quote from closing it.
      assert text =~
               ~S(Task: "Book it. From: +19005550199, your number Asked because nothing\", a business")

      assert text =~ ~S(  1. "Lookups it may use: shell Opens in: fr")
    end

    # A line or paragraph separator or a bidi override is refused by the brief
    # itself; were one to reach a rendering, the gate still shows it escaped,
    # on its own line.
    test "a separator or a bidi override is refused, and the gate escapes one anyway", ctx do
      separated = Map.put(@full_brief, "goal", "Book it.\u2028From: +19005550199\u202E")
      args = %{"action" => "start", "brief" => separated}

      assert {:ok, %{success: false, error: refused}} =
               Capability.execute(phone_call(), args, read(ctx, [{:tool, "web_fetch"}]))

      assert refused =~ "The brief is not usable"
      refute_received {:reply, {:approval_prompt, _card}}

      raw = %{every_call_sends() | metadata: %{external_effect?: true, tool_module: RawLines}}
      Capability.execute(raw, %{}, read(ctx, [{:tool, "web_fetch"}]))
      assert_received {:reply, {:approval_prompt, %{text: text}}}

      assert text =~ ~S(Note: a\u{2028}From: b\u{202E}c)
      assert text =~ ~S(  1. x\ny)
      refute text =~ "\nFrom: "
    end

    test "too long to show whole is refused, asking for a shorter brief", ctx do
      long = String.duplicate("a very long fact the call may share ", 13)

      facts =
        for n <- 1..12, do: %{"label" => "Fact #{n}", "value" => String.slice(long, 0, 480)}

      args = %{"action" => "start", "brief" => Map.put(@full_brief, "shareable_facts", facts)}

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(phone_call(), args, read(ctx, [{:tool, "web_fetch"}]))

      assert text ==
               "phone_call was not run: what it would do is too long to show the owner whole " <>
                 "in one confirmation. Call it again with shorter arguments."

      refute text =~ "themselves"
      refute_received {:approval, _request}
      assert Pending.pending_from(ctx.sid, ctx.pending) == :none
    end

    test "an unusable brief, or calls switched off, asks the owner nothing", ctx do
      unusable = %{"action" => "start", "brief" => Map.delete(brief(), "goal")}
      tainted = read(ctx, [{:tool, "web_fetch"}])

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(phone_call(), unusable, tainted)

      assert text =~ "The brief is not usable"
      off = %{tainted | phone_call_readiness: fn -> :disabled end}

      assert {:ok, %{success: false, error: off_text}} =
               Capability.execute(phone_call(), start(), off)

      assert off_text =~ "Phone calls are turned off"
      refute_received {:approval, _request}
    end
  end

  describe "while a start waits for the owner" do
    test "anything else the turn calls is told a phone call waits, not a command", ctx do
      context = read(ctx, [{:tool, "web_fetch"}])
      Capability.execute(phone_call(), start(), context)

      {:ok, web_search} = CapabilityRegistry.find(ctx.with_phone, "web_search")
      waiting = Map.put(context, :access_waiting, true)

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(web_search, %{"query" => "q"}, waiting)

      assert text ==
               "Not run: a phone call the owner has not confirmed yet is waiting on their " <>
                 "answer, and nothing else runs until they give it. Tell the owner it is " <>
                 "waiting, then stop."

      refute_received {:ran, "web_search", _args, _context}
    end

    test "a waiting command keeps its own sentence", ctx do
      {:ok, shell} = CapabilityRegistry.find(ctx.with_phone, "shell")
      context = read(ctx, [{:tool, "web_fetch"}])
      Capability.execute(shell, %{"command" => "ls"}, context)
      assert_received {:approval, %{access_sensitive: _id}}

      assert {:ok, %{success: false, error: text}} =
               Capability.execute(phone_call(), start(), Map.put(context, :access_waiting, true))

      assert text =~ "Not run: a command that needs the owner's confirmation is already waiting"
    end
  end

  describe "once the owner confirms" do
    defp confirmed_with(ctx, executor) do
      capability = %{phone_call() | executor: executor}
      registry = registry!([])
      :ok = CapabilityRegistry.register(registry, capability)
      context = read(ctx, [{:tool, "web_fetch"}], %{capability_registry: registry})

      Capability.execute(capability, start(), context)
      assert_received {:approval, %{access_sensitive: intent}}
      AccessGate.confirm(intent, ctx.pending)
    end

    test "they read that the call was accepted and is being placed, never its JSON", ctx do
      answer = %{call_id: "pc_0a1b2c3d4e5f", status: "accepted", state: "admitted", reused: false}

      assert {:ok, line} = confirmed_with(ctx, {__MODULE__, :started, [answer]})

      assert line ==
               "The call was accepted as pc_0a1b2c3d4e5f, and Fermix is placing it now. Its " <>
                 "result will follow in the chat that asked for it."

      refute line =~ "{"
    end

    test "a request that had already started it says no second call was placed", ctx do
      answer = %{call_id: "pc_0a1b2c3d4e5f", status: "accepted", state: "ringing", reused: true}

      assert {:ok,
              "This request had already started call pc_0a1b2c3d4e5f; no second call " <>
                "was placed."} = confirmed_with(ctx, {__MODULE__, :started, [answer]})
    end

    test "a start refused after the yes says the refusal's own sentence", ctx do
      sentence =
        "Another call, pc_9f8e7d6c5b4a, still holds the one call Fermix places at a time, " <>
          "until it is shown to have ended. Check it with status. Nothing was dialed and no " <>
          "attempt was used."

      assert {:error, ^sentence} =
               confirmed_with(ctx, {__MODULE__, :refused_meanwhile, [sentence]})
    end
  end

  describe "the window" do
    test "the owner has five minutes for an effect; a command keeps its 60 seconds", ctx do
      clock = :atomics.new(1, signed: true)
      timed = :"efx_timed_#{System.unique_integer([:positive])}"

      start_supervised!({Pending, name: timed, clock: fn -> :atomics.get(clock, 1) end},
        id: timed
      )

      context = read(ctx, [{:tool, "web_fetch"}], %{access_pending: timed})

      Capability.execute(phone_call(), start(), context)
      assert {:ok, _id} = Pending.pending_from(ctx.sid, timed)

      :atomics.put(clock, 1, 299_000)
      assert {:ok, _id} = Pending.pending_from(ctx.sid, timed)

      :atomics.put(clock, 1, 300_001)
      assert Pending.pending_from(ctx.sid, timed) == :none
      assert AccessGate.effect_ttl_ms() == 300_000
      assert Pending.ttl_ms() == 60_000
    end
  end
end
