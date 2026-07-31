defmodule FermixCore.Tools.ComputerUseTest do
  use ExUnit.Case, async: false

  alias Compux.Protocol
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.Session
  alias FermixCore.ComputerUse.Supervisor, as: CuSupervisor
  alias FermixCore.Sandbox.Config, as: SandboxConfig
  alias FermixCore.Tools.ComputerUse

  defmodule StubDriver do
    @behaviour Compux.Driver

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

  # Returns a configurable sidecar error from every action — exercises the tool's
  # action-failure messaging path (the real driver decodes `{"ok": false, ...}`
  # into the same `{:error, reason}` this returns).
  defmodule ErrorDriver do
    @behaviour Compux.Driver

    @impl true
    def start(opts), do: {:ok, %{error: Keyword.fetch!(opts, :error)}}

    @impl true
    def execute(%{error: error}, _request), do: {:error, error}

    @impl true
    def stop(_state), do: :ok
  end

  @context %{agent_name: "main", conversation_key: {"cli", "chat-cu", :root}}

  defp action_desc(params), do: params["properties"]["action"]["description"]

  # access is derived from the sandbox mode, so dynamic_parameters tests steer it
  # via [sandbox] mode rather than the computer_use config.
  defp put_access(mode) do
    Application.put_env(:fermix_core, :sandbox, %{SandboxConfig.default() | mode: mode})
  end

  defp strict_session do
    start_supervised!(
      {Session,
       [
         config: %{Config.normalize(enabled: true) | access: :strict},
         driver: {StubDriver, [test_pid: self()]},
         origin: :interactive,
         session_id: "cua_strict_#{System.unique_integer([:positive])}"
       ]}
    )
  end

  defp error_session(error) do
    start_supervised!(
      {Session,
       [
         config: Config.normalize(enabled: true),
         driver: {ErrorDriver, [error: error]},
         origin: :interactive,
         session_id: "cua_err_#{System.unique_integer([:positive])}"
       ]}
    )
  end

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

    test "static guidance treats accessibility metadata as optional pixel targeting help" do
      params = ComputerUse.parameters()
      action = params["properties"]["action"]["description"]
      region = params["properties"]["region"]["description"]
      x = params["properties"]["x"]["description"]

      assert ComputerUse.description() =~ "best-effort accessibility"
      assert ComputerUse.description() =~ "pixel"
      assert action =~ "empty"
      assert action =~ "pixel"
      assert region =~ "full-screen"
      assert region =~ "elements"
      assert x =~ "latest coordinate source"
    end

    test "failure_modes are tagged maps" do
      assert Enum.all?(ComputerUse.failure_modes(), &match?(%{tag: _, description: _}, &1))
    end
  end

  describe "dynamic_parameters/1 — live access mode folded into the action schema" do
    setup do
      prev = Application.get_env(:fermix_core, :sandbox)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:fermix_core, :sandbox)
          value -> Application.put_env(:fermix_core, :sandbox, value)
        end
      end)

      :ok
    end

    test "strict access surfaces the look-only guidance" do
      put_access(:strict)
      desc = action_desc(ComputerUse.dynamic_parameters(%{}))
      assert desc =~ "ACCESS=strict"
      assert desc =~ "look only"
    end

    test "standard access surfaces the confirm-irreversible guidance" do
      put_access(:standard)
      desc = action_desc(ComputerUse.dynamic_parameters(%{}))
      assert desc =~ "ACCESS=standard"
      assert desc =~ ~r/(confirm|ask the owner)/i
    end

    test "open access surfaces autonomous + the truly-dangerous higher bar" do
      put_access(:open)
      desc = action_desc(ComputerUse.dynamic_parameters(%{}))
      assert desc =~ "ACCESS=open"
      assert desc =~ ~r/(autonomous|without asking)/i
      assert desc =~ ~r/truly dangerous|catastrophic/i
    end

    test "the dynamic schema differs from the static parameters (mode is injected)" do
      put_access(:strict)

      refute action_desc(ComputerUse.dynamic_parameters(%{})) ==
               action_desc(ComputerUse.parameters())

      # action enum is unchanged either way
      assert ComputerUse.dynamic_parameters(%{})["properties"]["action"]["enum"] ==
               Protocol.actions()
    end
  end

  describe "execute/2 wiring" do
    setup do
      config = Config.normalize(enabled: true)

      session =
        start_supervised!(
          {Session,
           [
             config: config,
             driver: {StubDriver, [test_pid: self()]},
             origin: :interactive,
             session_id: "cua_tool_test"
           ]}
        )

      %{session: session, config: config}
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

    test "a coordinate mismatch names the latest coordinate source", %{
      session: session,
      config: config
    } do
      region = %{"x" => 10, "y" => 20, "w" => 300, "h" => 200}
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, screenshot} =
               ComputerUse.execute(%{"action" => "screenshot", "region" => region}, context)

      assert screenshot.success == true

      assert {:ok, result} =
               ComputerUse.execute(%{"action" => "left_click", "x" => 10, "y" => 20}, context)

      assert result.success == false
      assert result.error =~ "latest coordinate source"
      refute result.error =~ "last screenshot"
    end

    test "standard access: a mutating action auto-runs without confirmation", %{
      session: session,
      config: config
    } do
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, result} =
               ComputerUse.execute(%{"action" => "left_click", "x" => 10, "y" => 20}, context)

      assert result.success == true
      assert [%{type: :image}] = result.images
      assert_received {:driver_execute, %{"action" => "left_click"}}
    end

    test "an invalid action is rejected before any driver call", %{
      session: session,
      config: config
    } do
      context = Map.merge(@context, %{computer_use_session: session, computer_use_config: config})

      assert {:ok, result} = ComputerUse.execute(%{"action" => "teleport"}, context)
      assert result.success == false
      assert result.error =~ "invalid action"
      # The session's one-time input-control probe is setup, not the action.
      assert_received {:driver_execute, %{"action" => "probe"}}
      refute_received {:driver_execute, _}
    end
  end

  describe "strict access (look-only floor)" do
    test "a mutating action is refused before any driver call" do
      session = strict_session()
      context = Map.merge(@context, %{computer_use_session: session})

      assert {:ok, result} =
               ComputerUse.execute(%{"action" => "left_click", "x" => 1, "y" => 1}, context)

      assert result.success == false
      assert result.error =~ "strict"
      # The session's one-time input-control probe is setup, not the action.
      assert_received {:driver_execute, %{"action" => "probe"}}
      refute_received {:driver_execute, _}
    end

    test "a read-only action still runs in strict" do
      session = strict_session()
      context = Map.merge(@context, %{computer_use_session: session})

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == true
      assert [%{type: :image}] = result.images
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

  describe "action-failure messaging" do
    test "a no_active_display sidecar error becomes an honest, non-transient diagnosis" do
      session = error_session("no_active_display")

      context =
        Map.merge(@context, %{
          computer_use_session: session,
          computer_use_config: Config.normalize(enabled: true)
        })

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == false
      # Names the real cause (locked / asleep) and that retrying is futile; carries
      # no app-specific example. The raw machine token never leaks to the model.
      assert result.error =~ ~r/lock(ed)?/i
      assert result.error =~ ~r/asleep|awake/i
      refute result.error =~ "no_active_display"
    end

    test "an unrecognized sidecar error still surfaces verbatim (errors are never swallowed)" do
      session = error_session("scale_factor: backend hiccup")

      context =
        Map.merge(@context, %{
          computer_use_session: session,
          computer_use_config: Config.normalize(enabled: true)
        })

      assert {:ok, result} = ComputerUse.execute(%{"action" => "screenshot"}, context)
      assert result.success == false
      assert result.error =~ "action failed:"
      assert result.error =~ "scale_factor: backend hiccup"
    end
  end
end
