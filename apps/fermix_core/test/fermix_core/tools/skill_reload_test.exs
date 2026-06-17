defmodule FermixCore.Tools.SkillReloadTest do
  use ExUnit.Case, async: false

  alias FermixCore.Tools.SkillReload

  # The tool is a thin wrapper over MainAgent.reload_skills/1: its own logic is
  # shaping the registry summary into a JSON-safe payload (errors hold tuples
  # that Jason cannot encode) and classifying failures. A stub main-agent server
  # exercises every path hermetically — including a tuple-bearing error list a
  # real no-error reload would never produce.
  defmodule StubMainAgent do
    use GenServer

    def start_link(reply), do: GenServer.start_link(__MODULE__, reply)

    @impl true
    def init(reply), do: {:ok, reply}

    @impl true
    def handle_call(:reload_skills, _from, reply), do: {:reply, reply, reply}
  end

  test "reports the reload summary as JSON, rendering tuple errors to strings" do
    summary = %{
      version: 7,
      names: ["alpha", "beta"],
      added: ["beta"],
      removed: [],
      changed: ["alpha"],
      errors: [{:name_collision, "ghost", :plugin}]
    }

    {:ok, server} = StubMainAgent.start_link({:ok, summary})

    assert {:ok, result} = SkillReload.execute(%{}, %{main_agent_server: server})
    assert result.success == true

    payload = Jason.decode!(result.output)
    assert payload["version"] == 7
    assert payload["count"] == 2
    assert payload["names"] == ["alpha", "beta"]
    assert payload["added"] == ["beta"]
    assert payload["changed"] == ["alpha"]
    assert payload["errors"] == ["{:name_collision, \"ghost\", :plugin}"]
  end

  test "reports a registry reload failure as a tool error" do
    {:ok, server} = StubMainAgent.start_link({:error, :scan_failed})

    assert {:ok, result} = SkillReload.execute(%{}, %{main_agent_server: server})
    assert result.success == false
    assert result.error =~ "reload_failed"
    assert result.error =~ "scan_failed"
  end

  test "reports an unavailable main agent without raising" do
    assert {:ok, result} =
             SkillReload.execute(%{}, %{main_agent_server: :skill_reload_no_such_agent})

    assert result.success == false
    assert result.error =~ "agent_unavailable"
  end
end
