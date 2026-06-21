defmodule FermixCore.Tools.ComputerUseTest do
  use ExUnit.Case, async: false

  alias FermixCore.ComputerUse.Approval
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Protocol
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor
  alias FermixCore.Tools.ComputerUse

  defmodule StubDriver do
    @behaviour FermixCore.ComputerUse.Driver

    @png <<137, 80, 78, 71>>
    def png, do: @png

    @impl true
    def start(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

    @impl true
    def execute(%{test_pid: pid}, request) do
      send(pid, {:driver_execute, request})

      {:ok,
       %{
         "ok" => true,
         "data" => Base.encode64(@png),
         "mime" => "image/png",
         "width" => 800,
         "height" => 600
       }}
    end

    @impl true
    def stop(_state), do: :ok
  end

  @context %{agent_name: "main", conversation_key: {"cli", "chat-cu", :root}}

  describe "static surface" do
    test "name and category" do
      assert ComputerUse.name() == "computer_use"
      assert ComputerUse.category() == :computer
    end

    test "parameters is a discriminated union on action with the full action enum" do
      params = ComputerUse.parameters()
      assert params["type"] == "object"
      assert params["required"] == ["action"]
      assert params["properties"]["action"]["enum"] == Protocol.actions()
    end

    test "failure_modes are tagged maps" do
      assert Enum.all?(ComputerUse.failure_modes(), &match?(%{tag: _, description: _}, &1))
    end
  end

  describe "execute/2 wiring" do
    setup do
      start_supervised!(Approval)

      session =
        start_supervised!(
          {Session,
           [
             config: Config.normalize(enabled: true),
             driver: {StubDriver, [test_pid: self()]},
             origin: :interactive,
             session_id: "cua_tool_test"
           ]}
        )

      %{session: session, config: Config.normalize(enabled: true)}
    end

    test "disabled feature → inert with a clear message (no silent no-op)" do
      context = Map.put(@context, :computer_use_config, Config.normalize([]))

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == false
      assert result.error =~ "not active"
    end

    test "a read-only action auto-runs and returns the screenshot as an image", %{
      session: session,
      config: config
    } do
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == true
      assert [%{type: :image, mime_type: "image/png", data: data}] = result.images
      assert data == StubDriver.png()
    end

    test "a consequential action runs after the owner approves", %{
      session: session,
      config: config
    } do
      test_pid = self()
      surface = fn token, _action -> send(test_pid, {:prompted, token}) end

      context =
        Map.merge(@context, %{
          computer_use_session: session,
          computer_use_surface: surface,
          computer_use_config: config
        })

      task =
        Task.async(fn ->
          ComputerUse.execute(%{"action" => "left_click", "x" => 10, "y" => 20}, context)
        end)

      assert_receive {:prompted, token}
      assert :ok = Approval.resolve(token, :approve)

      assert {:ok, result} = Task.await(task)
      assert result.success == true
      assert [%{type: :image}] = result.images
    end

    test "a denied consequential action is not performed", %{session: session, config: config} do
      test_pid = self()
      surface = fn token, _action -> send(test_pid, {:prompted, token}) end

      context =
        Map.merge(@context, %{
          computer_use_session: session,
          computer_use_surface: surface,
          computer_use_config: config
        })

      task =
        Task.async(fn ->
          ComputerUse.execute(%{"action" => "type", "text" => "rm -rf"}, context)
        end)

      assert_receive {:prompted, token}
      assert :ok = Approval.resolve(token, :deny)

      assert {:ok, result} = Task.await(task)
      assert result.success == false
      assert result.error =~ "not confirmed"
      refute_received {:driver_execute, _}
    end

    test "a consequential action with no owner surface fails closed", %{
      session: session,
      config: config
    } do
      context =
        Map.merge(@context, %{
          computer_use_session: session,
          computer_use_surface: nil,
          computer_use_config: config
        })

      assert {:ok, result} =
               ComputerUse.execute(%{"action" => "left_click", "x" => 1, "y" => 1}, context)

      assert result.success == false
      assert result.error =~ "no_owner"
    end

    test "an invalid action is rejected before any driver call", %{
      session: session,
      config: config
    } do
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, result} = ComputerUse.execute(%{"action" => "teleport"}, context)
      assert result.success == false
      assert result.error =~ "invalid action"
      refute_received {:driver_execute, _}
    end
  end

  # No pre-placed `:computer_use_session` — the tool must acquire it itself through
  # SessionManager (keyed by `conversation_key`), which is the read-only `ask` path.
  describe "lazy session acquisition (read-only ask path)" do
    setup do
      start_supervised!(CuSupervisor)
      :ok
    end

    test "acquires the conversation's session and runs a read-only screenshot" do
      key = {"cli", "chat-ensure", :root}
      config = Config.normalize(enabled: true)

      # Pre-register the session under the conversation key; SessionManager.ensure
      # finds it via the registry and the tool drives a screenshot through it.
      start_supervised!(
        {Session,
         [
           name: {:via, Registry, {CuSupervisor.registry(), key}},
           config: config,
           driver: {StubDriver, [test_pid: self()]},
           origin: :interactive,
           session_id: "cua_ensure_test"
         ]}
      )

      context = %{agent_name: "main", conversation_key: key, computer_use_config: config}

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == true
      assert [%{type: :image, mime_type: "image/png", data: data}] = result.images
      assert data == StubDriver.png()
      assert_received {:driver_execute, %{"action" => "screenshot"}}
    end

    test "host mode + unattended origin fails closed with a clear message (no crash)" do
      # Enabled host config, no attended origin on the context → SessionManager refuses
      # to start a host session; the tool relays a clean error rather than raising.
      config = Config.normalize(enabled: true, mode: :host)

      context = %{
        agent_name: "main",
        conversation_key: {"cli", "host-x", :root},
        computer_use_config: config
      }

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == false
      assert result.error =~ "attended session"
    end
  end
end
