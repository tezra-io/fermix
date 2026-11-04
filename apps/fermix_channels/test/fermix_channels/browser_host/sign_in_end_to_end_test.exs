defmodule FermixChannels.BrowserHost.SignInEndToEndTest do
  @moduledoc """
  A sign-in end to end (M84): a model's turn in the real agent loop, the
  `browser` tool through the access gate, the browser tree's own profile and
  pane task, a fake Fermix app attached on protocol 2, and the owner answering
  in the chat through the real `/confirm` and `/deny` commands while the turn
  waits.

  `login_for` reaches the app, the owner's prompt is delivered on the turn's
  surface, and only the owner's answer moves the turn on: `page.sign_in`
  reaches the same task and tab on a yes, nothing is typed on a no, on no
  answer, or when the turn is stopped, and a later tool call of the same step
  runs only after the answer.

  Sync: it drives the browser tree's own availability process and profile
  registry, the gate's own store of waiting calls and the channel's token
  store, as the owner's commands find them.
  """
  use ExUnit.Case, async: false

  alias FermixChannels.Gateway.Authorizer
  alias FermixChannels.Gateway.Commands
  alias FermixChannels.Gateway.Commands.Sandbox, as: SandboxCommand
  alias FermixChannels.Gateway.Message
  alias FermixChannels.Gateway.Source
  alias FermixCore.AgentLoop
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Browser.Scope
  alias FermixCore.Capabilities.Builtin, as: BuiltinCapability
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixTestSupport.FakeBrowserHostConnection
  alias FermixTestSupport.TelemetryCapture

  @owner "owner-1"
  @username "person@example.com"
  @sign_in %{
    "action" => "act",
    "kind" => "sign_in",
    "site" => "example.com",
    "username_ref" => "textbox_1",
    "password_ref" => "textbox_2"
  }
  @late_confirm "Confirmed, but that request expired or was already handled"

  # The provider: each step answers the next scripted turn, and every tool
  # result the loop hands back is kept for the test to read.
  defmodule ScriptedAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts), do: next()

    @impl true
    def continue(_provider_state, tool_results, _opts) do
      Process.put(:tool_results, Process.get(:tool_results, []) ++ tool_results)
      next()
    end

    @impl true
    def to_provider_tools(capabilities), do: capabilities
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response
    @impl true
    def supports_streaming?, do: false

    defp next do
      case Process.get(:script, []) do
        [calls | rest] ->
          Process.put(:script, rest)
          {:ok, step(calls)}

        [] ->
          {:error, "the script ran out"}
      end
    end

    defp step(:done), do: response("Done.", [])
    defp step(calls), do: response("", calls)

    defp response(content, calls) do
      %{
        content: content,
        tool_calls:
          calls
          |> Enum.with_index(1)
          |> Enum.map(fn {{name, args}, index} ->
            id = "call_#{System.unique_integer([:positive])}_#{index}"
            %{id: "fc_" <> id, call_id: id, name: name, arguments: Jason.encode!(args)}
          end),
        provider_state: %{step: System.unique_integer()},
        usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10},
        model: "scripted"
      }
    end
  end

  # Stands in for `computer_use`, a later call in the same step: when it runs,
  # it reports what the app had been asked by then.
  def computer_use(_args, _context, test, connection) do
    send(test, {:computer_use_ran, request_types(connection)})
    {:ok, %{success: true, output: "screen read", error: nil}}
  end

  setup do
    previous = Application.get_env(:fermix_channels, :telegram, [])

    Application.put_env(:fermix_channels, :telegram,
      owner_user_id: @owner,
      allowed_user_ids: [@owner],
      command_allowlist: []
    )

    on_exit(fn -> Application.put_env(:fermix_channels, :telegram, previous) end)

    registry = :"sign_in_e2e_caps_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})
    turns = start_supervised!({Task.Supervisor, name: nil}, id: make_ref())
    conversation = {"telegram", "sign-in-e2e-#{System.unique_integer([:positive])}", :root}
    # The pane task runs in the conversation's own pane profile.
    {:ok, scope} = Scope.owner_key(%{source_trust: :operator, conversation_key: conversation})
    pane = Scope.pane_key(scope, conversation)
    on_exit(fn -> ProfileManager.stop_owner(pane) end)

    %{registry: registry, turns: turns, conversation: conversation, pane: pane}
  end

  test "the owner's /confirm in the chat lets the turn type the login on the same task and tab",
       ctx do
    connection = attach_app(ctx)
    :ok = register(ctx, connection)
    session = "sign-in-e2e-#{System.unique_integer([:positive])}"
    TelemetryCapture.attach([[:fermix, :tool, :exec]], session_id: session)

    turn = start_turn(ctx, session, [[open()], [{"browser", @sign_in}, {"computer_use", %{}}]])

    assert_receive {:asked, _waiter, %{access_sensitive: _id}}
    assert_receive {:prompt, {:approval_prompt, prompt, token}}
    assert prompt =~ "Sign in to example.com as #{@username}?"

    # The turn waits in its call: the app was asked which login fits the page,
    # nothing has been typed, and the later call of the step has not run.
    assert request_types(connection) == ["tab.open", "page.login_for"]
    refute_received {:computer_use_ran, _requests}

    assert :ok = chat("/confirm #{token}")
    assert_receive {:chat_reply, "Approved."}

    assert {{:ok, %{response: "Done."}}, results} = Task.await(turn)
    assert_receive {:computer_use_ran, seen}
    assert seen == ["tab.open", "page.login_for", "page.sign_in"]

    [{"tab.open", open}, {"page.login_for", lookup}, {"page.sign_in", typed}] =
      FakeBrowserHostConnection.requests(connection)

    assert lookup == %{"tab_id" => "t1", "site" => "example.com"}

    assert typed == %{
             "tab_id" => "t1",
             "site" => "example.com",
             "login_site" => "example.com",
             "username_ref" => 11,
             "password_ref" => 12,
             "observe" => true,
             "snapshot" => open["snapshot"]
           }

    signed = results |> Enum.at(1) |> Map.fetch!(:output)
    assert signed =~ ~s("ok":true)
    assert signed =~ ~s("filled":["username","password"])
    assert signed =~ ~s("site":"example.com")
    assert signed =~ ~s("username":"#{@username}")

    # One model tool call, one event, with the kind and the site in its safe
    # metadata and never the username.
    sign_ins = for {:telemetry, _, _, %{tool: "browser", kind: "sign_in"} = m} <- drain(), do: m
    assert [metadata] = sign_ins
    assert metadata.success == true
    assert metadata.site == "example.com"
    assert metadata.backend == "fermix_app"
    refute inspect(Map.drop(metadata, [:input, :output])) =~ @username
  end

  test "the owner's /deny types nothing, and the turn hears it was refused", ctx do
    connection = attach_app(ctx)
    :ok = register(ctx, connection)
    turn = start_turn(ctx, session(), [[open()], [{"browser", @sign_in}]])

    assert_receive {:prompt, {:approval_prompt, _prompt, token}}
    assert :ok = chat("/deny #{token}")
    assert_receive {:chat_reply, "Denied."}

    assert {{:ok, _result}, results} = Task.await(turn)
    assert results |> Enum.at(1) |> Map.fetch!(:output) =~ "sign_in_denied"
    refute "page.sign_in" in request_types(connection)
  end

  # The window's end is the waiting call's own timer message, delivered here
  # by hand; no clock is waited on.
  @tag :capture_log
  test "no answer within the window types nothing, and a late /confirm finds nothing", ctx do
    connection = attach_app(ctx)
    :ok = register(ctx, connection)
    turn = start_turn(ctx, session(), [[open()], [{"browser", @sign_in}]])

    assert_receive {:asked, waiter, %{access_sensitive: id}}
    assert_receive {:prompt, {:approval_prompt, _prompt, token}}
    send(waiter, {:access_timeout, id})

    assert {{:ok, _result}, results} = Task.await(turn)
    assert results |> Enum.at(1) |> Map.fetch!(:output) =~ "sign_in_unanswered"
    refute "page.sign_in" in request_types(connection)

    assert :ok = chat("/confirm #{token}")
    assert_receive {:chat_reply, reply}
    assert reply =~ @late_confirm
  end

  # `/stop` ends the turn's task with the call still waiting (the queue's own
  # `Task.Supervisor.terminate_child/2`): nothing is left to type, the pane
  # task's tabs are released with it, and a late /confirm finds nothing.
  test "a stopped turn types nothing, releases its tabs, and a late /confirm finds nothing",
       ctx do
    connection = attach_app(ctx)
    :ok = register(ctx, connection)
    turn = start_turn(ctx, session(), [[open()], [{"browser", @sign_in}]])

    assert_receive {:prompt, {:approval_prompt, _prompt, token}}
    [{profile, _value}] = Registry.lookup(FermixCore.Browser.Registry, {ctx.pane, "fermix"})
    watched = Process.monitor(profile)

    :ok = Task.Supervisor.terminate_child(ctx.turns, turn.pid)
    assert_receive {:DOWN, ^watched, :process, ^profile, _reason}

    assert [_task_id] = FakeBrowserHostConnection.releases(connection)
    refute "page.sign_in" in request_types(connection)

    assert :ok = chat("/confirm #{token}")
    assert_receive {:chat_reply, reply}
    assert reply =~ @late_confirm
  end

  # `submit: true` sends the login form in the same call once the login is
  # typed: the fill is not looked at, the submit is, and the model reads the
  # submit's look with the sign-in's receipt beside it.
  test "a sign-in that submits types the login, then submits the form and looks once", ctx do
    connection = attach_app(ctx)
    :ok = register(ctx, connection)
    submitting = Map.put(@sign_in, "submit", true)
    turn = start_turn(ctx, session(), [[open()], [{"browser", submitting}]])

    assert_receive {:prompt, {:approval_prompt, _prompt, token}}
    assert request_types(connection) == ["tab.open", "page.login_for"]
    assert :ok = chat("/confirm #{token}")
    assert_receive {:chat_reply, "Approved."}

    assert {{:ok, %{response: "Done."}}, results} = Task.await(turn)

    assert [
             {"tab.open", open},
             {"page.login_for", _lookup},
             {"page.sign_in", typed},
             {"page.act", submitted}
           ] = FakeBrowserHostConnection.requests(connection)

    assert typed["observe"] == false
    refute Map.has_key?(typed, "snapshot")

    assert submitted == %{
             "tab_id" => "t1",
             "kind" => "submit",
             "ref" => 12,
             "observe" => true,
             "snapshot" => open["snapshot"]
           }

    result = results |> Enum.at(1) |> Map.fetch!(:output) |> tool_json()
    assert result["action"] == "submit"
    assert result["page"] == "changed"
    assert result["url"] == "https://example.com/home"
    assert result["snapshot"] =~ ~s([link] "Your account")
    assert result["fill"]["filled"] == ["username", "password"]
    assert result["fill"]["site"] == "example.com"
    assert result["fill"]["username"] == @username
  end

  test "a username alone is typed with no question to the owner", ctx do
    connection = attach_app(ctx)
    :ok = register(ctx, connection)
    username = Map.delete(@sign_in, "password_ref")
    turn = start_turn(ctx, session(), [[open()], [{"browser", username}]])

    assert {{:ok, _result}, results} = Task.await(turn)
    refute_received {:asked, _waiter, _request}
    assert results |> Enum.at(1) |> Map.fetch!(:output) =~ ~s("filled":["username"])

    assert [{"tab.open", _}, {"page.login_for", _}, {"page.sign_in", typed}] =
             FakeBrowserHostConnection.requests(connection)

    refute Map.has_key?(typed, "password_ref")
  end

  test "a page with no saved login says where to add one, with no question to the owner", ctx do
    connection = attach_app(ctx, no_login: true)
    :ok = register(ctx, connection)
    turn = start_turn(ctx, session(), [[open()], [{"browser", @sign_in}]])

    assert {{:ok, _result}, results} = Task.await(turn)
    refute_received {:asked, _waiter, _request}
    output = results |> Enum.at(1) |> Map.fetch!(:output)
    assert output =~ "sign_in_no_login"
    assert output =~ "Settings > Browser > Website logins"
    assert request_types(connection) == ["tab.open", "page.login_for"]
  end

  # ── the turn ─────────────────────────────────────────────────────────────

  # The owner's own chat turn, in its own process as the queue runs one: the
  # approval closure is the gateway's, and it reports the waiting call and its
  # record; the reply closure reports what the owner is shown.
  defp start_turn(ctx, session, steps) do
    test = self()

    origin = %{
      channel: "telegram",
      chat_id: "chat-1",
      thread_ts: nil,
      user_id: @owner,
      resume: nil
    }

    context = %{
      agent_name: "main",
      session_id: session,
      source_trust: :operator,
      computer_use_origin: :interactive,
      conversation_key: ctx.conversation,
      chat_type: "private",
      capability_registry: ctx.registry,
      reply_fn: fn part -> send(test, {:prompt, part}) end,
      approval_fn: fn request ->
        send(test, {:asked, self(), request})
        SandboxCommand.store_pending_grant(request, origin)
      end
    }

    Task.Supervisor.async_nolink(ctx.turns, fn ->
      Process.put(:script, steps ++ [:done])

      result =
        AgentLoop.run(
          messages: [%{role: "user", content: "Sign me in to my Example account."}],
          adapter: ScriptedAdapter,
          adapter_opts: [model: "scripted"],
          capability_registry: ctx.registry,
          trust: :operator,
          context: context
        )

      {result, Process.get(:tool_results, [])}
    end)
  end

  defp open, do: {"browser", %{"action" => "open", "url" => "https://example.com/login"}}

  defp session, do: "sign-in-e2e-#{System.unique_integer([:positive])}"

  defp register(ctx, connection) do
    computer_use =
      Capability.new(%{
        name: "computer_use",
        description: "Read the screen.",
        parameters: %{"type" => "object"},
        kind: :builtin,
        executor: {__MODULE__, :computer_use, [self(), connection]},
        policy_class: :read_only
      })

    :ok =
      CapabilityRegistry.register(
        ctx.registry,
        BuiltinCapability.from_tool_module(FermixCore.Tools.Browser)
      )

    CapabilityRegistry.register(ctx.registry, computer_use)
  end

  # ── the owner in the chat ────────────────────────────────────────────────

  defp chat(content) do
    test = self()

    message =
      Message.new!(%{
        id: "msg-#{System.unique_integer([:positive])}",
        content: content,
        sender: "owner",
        channel: "telegram",
        chat_id: "chat-1",
        reply_target: "chat-1",
        metadata: %{user_id: @owner}
      })

    {:ok, authorization} =
      message |> Map.from_struct() |> Source.from_message(nil) |> Authorizer.resolve()

    reply = fn
      {:text, text} -> send(test, {:chat_reply, text}) && :ok
      _other -> :ok
    end

    Commands.dispatch(Commands.parse(message), reply, %{authorization: authorization})
  end

  # ── the app ──────────────────────────────────────────────────────────────

  # A fake Fermix app on protocol 2, attached to the browser tree's own
  # availability process: it answers a login page, the login saved for it
  # (or none), and the fill.
  defp attach_app(_ctx, opts \\ []) do
    {:ok, connection} = FakeBrowserHostConnection.start_link(answers(opts))
    on_exit(fn -> Process.exit(connection, :kill) end)
    :ok = HostAvailability.attached(HostAvailability, connection, 1, 2)
    :ok = HostAvailability.report(HostAvailability, true, nil)
    connection
  end

  defp answers(opts) do
    login =
      if Keyword.get(opts, :no_login),
        do: {:error, %{"reason" => "sign_in_no_login", "message" => "no login for this site"}},
        else: {:ok, %{"login_site" => "example.com", "username" => @username}}

    %{
      "tab.open" =>
        {:ok,
         %{
           "tab_id" => "t1",
           "url" => "https://example.com/login",
           "title" => "Sign in",
           "page" => login_page()
         }},
      "page.login_for" => login,
      "page.sign_in" => fn payload ->
        filled = Enum.filter(["username", "password"], &Map.has_key?(payload, &1 <> "_ref"))

        {:ok,
         %{
           "url" => "https://example.com/login",
           "title" => "Sign in",
           "filled" => filled,
           "page" => login_page()
         }}
      end,
      "page.act" =>
        {:ok, %{"url" => "https://example.com/home", "title" => "Home", "page" => home_page()}}
    }
  end

  # The page a submitted login lands on.
  defp home_page do
    %{
      "url" => "https://example.com/home",
      "title" => "Home",
      "ready_state" => "complete",
      "nodes" => [
        %{
          "nodeId" => "1",
          "role" => %{"value" => "RootWebArea"},
          "name" => %{"value" => "Home"},
          "childIds" => ["2"]
        },
        %{
          "nodeId" => "2",
          "backendDOMNodeId" => 21,
          "role" => %{"value" => "link"},
          "name" => %{"value" => "Your account"}
        }
      ]
    }
  end

  defp login_page do
    %{
      "url" => "https://example.com/login",
      "title" => "Sign in",
      "ready_state" => "complete",
      "nodes" => [
        %{
          "nodeId" => "1",
          "role" => %{"value" => "RootWebArea"},
          "name" => %{"value" => "Sign in"},
          "childIds" => ["2", "3", "4"]
        },
        %{
          "nodeId" => "2",
          "backendDOMNodeId" => 11,
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Email"}
        },
        %{
          "nodeId" => "3",
          "backendDOMNodeId" => 12,
          "role" => %{"value" => "textbox"},
          "name" => %{"value" => "Password"}
        },
        %{
          "nodeId" => "4",
          "backendDOMNodeId" => 13,
          "role" => %{"value" => "button"},
          "name" => %{"value" => "Sign in"}
        }
      ]
    }
  end

  defp request_types(connection),
    do: connection |> FakeBrowserHostConnection.requests() |> Enum.map(&elem(&1, 0))

  # A browser result reaches the model wrapped as untrusted data; its JSON is
  # the one line of the wrapper that is an object.
  defp tool_json(output) do
    output |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "{")) |> Jason.decode!()
  end

  defp drain(acc \\ []) do
    receive do
      {:telemetry, _event, _measurements, _metadata} = event -> drain([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
