defmodule FermixCore.Tools.RequestDirectoryAccessTest do
  use ExUnit.Case, async: false

  alias FermixCore.AgentLoop
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Sandbox.Config
  alias FermixCore.Sandbox.PathPolicy
  alias FermixCore.Tools.RequestDirectoryAccess, as: Tool

  # Minimal provider adapter that replays a queued list of turns, so the real
  # AgentLoop can drive the tool end to end (the finding is a loop-integration
  # bug, not a return-value bug).
  defmodule LoopMockAdapter do
    @behaviour FermixCore.Providers.Adapter

    @impl true
    def chat(_messages, _capabilities, _opts), do: next_response()
    @impl true
    def continue(_state, _tool_results, _opts), do: next_response()
    @impl true
    def to_provider_tools(capabilities), do: capabilities
    @impl true
    def parse_tool_calls(_response), do: []
    @impl true
    def parse_response(response), do: response
    @impl true
    def supports_streaming?, do: false

    defp next_response do
      case Process.get(:loop_responses, []) do
        [next | rest] ->
          Process.put(:loop_responses, rest)
          next

        [] ->
          {:error, "no mock responses left"}
      end
    end
  end

  setup do
    home = FermixTestSupport.SafeRm.make_tmp_dir!("req-dir-access")
    os_home = Path.join(home, "oshome")
    workspace = Path.join(home, "workspace")
    grant_dir = Path.join(home, "grantme")
    File.mkdir_p!(os_home)
    File.mkdir_p!(workspace)
    File.mkdir_p!(grant_dir)

    previous_env = System.get_env("FERMIX_HOME")
    previous_sandbox = Application.get_env(:fermix_core, :sandbox)
    System.put_env("FERMIX_HOME", home)

    Application.put_env(
      :fermix_core,
      :sandbox,
      Config.normalize(home: home, os_home: os_home, mode: :strict, workspace_root: workspace)
    )

    on_exit(fn ->
      restore_env(previous_env)
      restore_sandbox(previous_sandbox)
      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{workspace: workspace, grant_dir: grant_dir}
  end

  # An attended operator context whose reply_fn and approval_fn report every call
  # back to the test, so a fail-closed gate is provable by the ABSENCE of a report.
  defp attended_context(overrides \\ %{}) do
    test_pid = self()

    base = %{
      agent_name: "test",
      conversation_key: :test,
      source_trust: :operator,
      reply_fn: fn part ->
        send(test_pid, {:reply_called, part})
        :ok
      end,
      approval_fn: fn request ->
        send(test_pid, {:approval_called, request})
        {:ok, "TOKEN123", :new}
      end
    }

    Map.merge(base, overrides)
  end

  describe "gate (fail-closed)" do
    test "a guest turn is refused with no approval or reply call" do
      context = attended_context(%{source_trust: :guest})

      assert {:ok, %{success: false, error: error}} =
               Tool.execute(%{"path" => "/tmp/x", "reason" => "need it"}, context)

      assert error =~ "attended owner conversation"
      refute_received {:approval_called, _}
      refute_received {:reply_called, _}
    end

    test "a turn with no reply_fn is refused with no approval call", %{grant_dir: grant_dir} do
      context = attended_context() |> Map.delete(:reply_fn)

      assert {:ok, %{success: false, error: error}} =
               Tool.execute(%{"path" => grant_dir, "reason" => "need it"}, context)

      assert error =~ "attended owner conversation"
      refute_received {:approval_called, _}
    end

    test "a turn with no approval_fn is refused", %{grant_dir: grant_dir} do
      context = attended_context() |> Map.delete(:approval_fn)

      assert {:ok, %{success: false, error: error}} =
               Tool.execute(%{"path" => grant_dir, "reason" => "need it"}, context)

      assert error =~ "attended owner conversation"
      refute_received {:reply_called, _}
    end
  end

  describe "validation before prompting" do
    test "refuses an unsafe root without prompting the owner" do
      context = attended_context()

      assert {:ok, %{success: false, error: error}} =
               Tool.execute(%{"path" => "/", "reason" => "everything"}, context)

      assert error =~ "can't request access"
      refute_received {:approval_called, _}
      refute_received {:reply_called, _}
    end

    test "short-circuits when the path is already allowed", %{workspace: workspace} do
      inside = Path.join(workspace, "sub")
      File.mkdir_p!(inside)
      context = attended_context()

      assert {:ok, %{success: true, output: output}} =
               Tool.execute(%{"path" => inside, "reason" => "already here"}, context)

      assert output =~ "already allowed"
      refute_received {:approval_called, _}
      refute_received {:reply_called, _}
    end
  end

  describe "happy path (real capability execution)" do
    test "prompts the owner with the canonical path + token via the registry executor",
         %{grant_dir: grant_dir} do
      cap = Builtin.from_tool_module(Tool)
      canonical = PathPolicy.canonical_path(grant_dir)

      assert {:ok, %{success: true, output: output}} =
               Capability.execute(
                 cap,
                 %{"path" => grant_dir, "reason" => "the task spans this repo"},
                 attended_context()
               )

      assert_received {:approval_called, %{path: ^canonical, reason: "the task spans this repo"}}
      assert_received {:reply_called, {:text, prompt}}
      assert prompt =~ canonical
      assert prompt =~ "/confirm TOKEN123"
      assert prompt =~ "the task spans this repo"
      assert output =~ "TOKEN123"
    end

    test "an :existing dedupe result sends NO second owner message", %{grant_dir: grant_dir} do
      test_pid = self()

      context =
        attended_context(%{
          approval_fn: fn request ->
            send(test_pid, {:approval_called, request})
            {:ok, "DUP45678", :existing}
          end
        })

      assert {:ok, %{success: true, output: output}} =
               Tool.execute(%{"path" => grant_dir, "reason" => "spans repo"}, context)

      assert_received {:approval_called, _}
      refute_received {:reply_called, _}
      assert output =~ "already pending"
      assert output =~ "DUP45678"
    end
  end

  describe "advertise?/1" do
    defp advertise_ctx(overrides) do
      Map.merge(
        %{source_trust: :operator, reply_fn: fn _ -> :ok end, approval_fn: fn _ -> :ok end},
        overrides
      )
    end

    test "advertised for an attended, top-level operator turn" do
      assert Tool.advertise?(advertise_ctx(%{}))
    end

    test "hidden for a guest turn" do
      refute Tool.advertise?(advertise_ctx(%{source_trust: :guest}))
    end

    test "hidden without an approval_fn" do
      refute Tool.advertise?(advertise_ctx(%{}) |> Map.delete(:approval_fn))
    end

    test "hidden without a reply_fn" do
      refute Tool.advertise?(advertise_ctx(%{}) |> Map.delete(:reply_fn))
    end

    test "hidden inside a subagent (depth > 0)" do
      refute Tool.advertise?(advertise_ctx(%{subagent_depth: 1}))
    end
  end

  describe "agent-loop integration (must not stall the turn)" do
    test "a sole request_directory_access call with no prose still continues the turn",
         %{grant_dir: grant_dir} do
      test_pid = self()
      cap = Builtin.from_tool_module(Tool)

      context = %{
        agent_name: "test",
        conversation_key: :test,
        source_trust: :operator,
        reply_fn: fn part ->
          send(test_pid, {:reply_called, part})
          :ok
        end,
        approval_fn: fn request ->
          send(test_pid, {:approval_called, request})
          {:ok, "LOOPTOK1", :new}
        end
      }

      Process.put(:loop_responses, [
        loop_turn("",
          tool_calls: [
            loop_tool_call("request_directory_access", %{
              "path" => grant_dir,
              "reason" => "spans repo"
            })
          ]
        ),
        loop_turn("I've asked the owner to approve access.")
      ])

      assert {:ok, result} =
               AgentLoop.run(
                 messages: [%{role: "user", content: "work in that repo"}],
                 adapter: LoopMockAdapter,
                 adapter_opts: [model: "mock"],
                 context: context,
                 capabilities: [cap],
                 dispatchable_capabilities: [cap]
               )

      # The owner received the prompt via reply_fn...
      assert_received {:approval_called, _}
      assert_received {:reply_called, {:text, prompt}}
      assert prompt =~ "/confirm LOOPTOK1"

      # ...and the loop CONTINUED past the tool (finding #1/#2): the model's
      # follow-up text is the reply, so the turn never ends with an empty
      # response and the queue never emits the canned "I didn't get a response".
      assert result.response == "I've asked the owner to approve access."
      refute result.response == ""
    end

    test "the tool declares no terminal?/0 hook (never a terminal side-effect)" do
      refute function_exported?(Tool, :terminal?, 0)
    end
  end

  defp loop_turn(content, opts \\ []) do
    {:ok,
     %{
       content: content,
       tool_calls: Keyword.get(opts, :tool_calls, []),
       provider_state: %{turn: System.unique_integer()},
       usage: %{prompt_tokens: 10, completion_tokens: 0, total_tokens: 10},
       model: "mock"
     }}
  end

  defp loop_tool_call(name, arguments) do
    call_id = "c#{System.unique_integer([:positive])}"

    %{
      id: "fc_#{call_id}",
      call_id: call_id,
      name: name,
      arguments: Jason.encode!(arguments)
    }
  end

  defp restore_env(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_env(value), do: System.put_env("FERMIX_HOME", value)
  defp restore_sandbox(nil), do: Application.delete_env(:fermix_core, :sandbox)
  defp restore_sandbox(value), do: Application.put_env(:fermix_core, :sandbox, value)
end
