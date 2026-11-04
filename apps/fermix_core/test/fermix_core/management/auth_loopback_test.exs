defmodule FermixCore.Management.AuthLoopbackTest do
  # A sign-in a desktop starts over the rail (M75 D17): the management caller
  # reaches the flow, so its loopback listener is recorded as that desktop's,
  # and a port the desktop cannot open is the sign-in's failure sentence.
  use ExUnit.Case, async: true

  alias FermixCore.Management.Copy
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Router

  @desktop {:desktop, "desk-1"}

  setup context do
    tasks = :"auth_loopback_tasks_#{:erlang.phash2(context.test)}"
    start_supervised!({Task.Supervisor, name: tasks}, id: tasks)

    server =
      start_supervised!(
        {Jobs,
         name: :"auth_loopback_jobs_#{:erlang.phash2(context.test)}", task_supervisor: tasks}
      )

    %{jobs: [server: server]}
  end

  defp start(provider, operation_opts, router_opts) do
    request = %{method: "auth.start", protocol_version: 2, params: %{"provider" => provider}}
    Router.route(request, [operation_opts: operation_opts] ++ router_opts)
  end

  defp capturing_login(test) do
    fn opts ->
      send(test, {:login_opts, opts})
      {:error, :callback_timeout}
    end
  end

  test "a desktop's sign-in carries the desktop to the flow; a local one carries nobody", %{
    jobs: jobs
  } do
    login = capturing_login(self())

    assert {:ok, _view} = start("xai", [jobs: jobs, login: login], actor: @desktop)
    assert_receive {:login_opts, opts}
    assert Keyword.fetch!(opts, :loopback_owner) == @desktop

    assert {:ok, _view} = start("xai", [jobs: jobs, login: login], [])
    assert_receive {:login_opts, opts}
    refute Keyword.has_key?(opts, :loopback_owner)
  end

  test "every browser sign-in passes it on: ChatGPT and an MCP server", %{jobs: jobs} do
    test = self()

    assert {:ok, _view} =
             start("openai_codex", [jobs: jobs, login: capturing_login(test)], actor: @desktop)

    assert_receive {:login_opts, opts}
    assert Keyword.fetch!(opts, :loopback_owner) == @desktop

    server = %{name: "notes", transport: :http, auth: :auto, url: "https://mcp.example/mcp"}

    mcp_login = fn ^server, opts ->
      send(test, {:mcp_opts, opts})
      {:error, :callback_timeout}
    end

    operation_opts = [jobs: jobs, servers: fn -> [server] end, mcp_login: mcp_login]
    assert {:ok, _view} = start("mcp:notes", operation_opts, actor: @desktop)
    assert_receive {:mcp_opts, opts}
    assert Keyword.fetch!(opts, :loopback_owner) == @desktop
  end

  test "a port the desktop cannot open is the sign-in's failure sentence", %{jobs: jobs} do
    failure = %{desktop: "Studio Mac", port: 1455, reason: :port_in_use}
    login = fn _opts -> {:error, {:loopback_forward_failed, failure}} end

    assert {:ok, view} = start("xai", [jobs: jobs, login: login], actor: @desktop)
    assert view["status"] == "failed"

    sentence = view["failure"]["sentence"]

    assert sentence ==
             "Your Studio Mac could not open port 1455 to receive the sign-in reply: " <>
               "another program is using it. Free the port and sign in again."

    assert Copy.violations(sentence, :prose, ["Studio Mac"]) == []

    for {reason, words} <- [
          not_permitted: "the system did not allow it",
          failed: "it could not listen there"
        ] do
      login = fn _opts -> {:error, {:loopback_forward_failed, %{failure | reason: reason}}} end
      assert {:ok, view} = start("xai", [jobs: jobs, login: login], actor: @desktop)
      assert view["failure"]["sentence"] =~ words
    end
  end
end
