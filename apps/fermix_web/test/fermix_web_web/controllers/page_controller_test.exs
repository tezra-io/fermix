defmodule FermixWebWeb.PageControllerTest do
  use FermixWebWeb.ConnCase

  import Phoenix.LiveViewTest

  alias FermixCore.Health
  alias FermixCore.Setup.AccessToken
  alias FermixCore.Setup.BootReport
  alias FermixWebWeb.HomeLive

  defmodule FakeHomeSnapshot do
    def snapshot do
      {:ok,
       %{
         overview: %{
           readiness: %{status: :ready, failures: []},
           provider: %{active: :openai, model: "gpt-5.4-mini"},
           agents: %{
             main: %{
               health: :online,
               activity: :idle,
               status: :idle,
               active_conversations: 0,
               pending_conversations: 0
             },
             skill_workers: 1,
             running_skill_workers: 1
           },
           jobs: %{
             scheduled: 1,
             running: 0,
             paused: 0,
             failed_recent: 0,
             status: :ready,
             error: nil
           },
           realtime: %{
             enabled: true,
             status: :ready,
             provider: :openai,
             model: "gpt-realtime-2",
             socket_path: "/Users/example/.fermix-dev/realtime.sock",
             socket_alive: true,
             active_sessions: 0,
             active_clients: 1,
             companion_connected?: true
           }
         },
         agents: %{
           main: %{
             name: "main",
             health: :online,
             activity: :idle,
             status: :idle,
             active_conversations: 0,
             pending_conversations: 0,
             provider: :openai_codex,
             model: nil
           },
           skill_workers: [
             %{
               name: "research",
               role: :worker,
               session_id: "session-1",
               status: :running,
               parent: "main"
             }
           ],
           counts: %{skill_workers: 1, running_skill_workers: 1}
         },
         jobs: %{
           status: :ready,
           error: nil,
           counts: %{disabled: 0, paused: 0, running: 0, scheduled: 1, total: 1},
           jobs: [
             %{
               id: "daily_digest",
               name: "Daily Digest",
               state: "scheduled",
               enabled?: true,
               schedule_expr: "every 15 minutes",
               next_run_at: ~U[2026-05-05 12:00:00Z],
               last_status: "ok",
               delivery_mode: "origin"
             }
           ]
         }
       }}
    end
  end

  defmodule BrokenHomeSnapshot do
    def snapshot do
      {:error, {:badmatch, self(), "/Users/example/.fermix-dev/auth.json"}}
    end
  end

  setup %{conn: conn} do
    provider_config = Application.get_env(:fermix_core, :providers)
    telegram_config = Application.get_env(:fermix_channels, :telegram)
    personalization = Application.get_env(:fermix_core, :personalization, [])
    agent = Application.get_env(:fermix_core, :agent, [])
    home_snapshot = Application.get_env(:fermix_web, :home_snapshot)
    fermix_home = System.get_env("FERMIX_HOME")
    tmp_home = FermixTestSupport.SafeRm.make_tmp_dir!("page-controller")
    System.put_env("FERMIX_HOME", tmp_home)

    Application.put_env(:fermix_core, :personalization,
      user_name: "Test User",
      timezone: "UTC",
      communication_style: "neutral and direct"
    )

    Application.put_env(:fermix_core, :agent, name: "fermix")

    on_exit(fn ->
      restore_env(:fermix_core, :providers, provider_config)
      restore_env(:fermix_channels, :telegram, telegram_config)
      Application.put_env(:fermix_core, :personalization, personalization)
      Application.put_env(:fermix_core, :agent, agent)
      restore_env(:fermix_web, :home_snapshot, home_snapshot)

      case fermix_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(tmp_home)
      BootReport.refresh()
    end)

    %{conn: authorize_setup(conn)}
  end

  test "GET / redirects to /setup when readiness is incomplete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)
    BootReport.refresh()

    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / renders home when readiness is complete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
    Application.put_env(:fermix_web, :home_snapshot, FakeHomeSnapshot)
    BootReport.refresh()

    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ "Fermix"
    assert body =~ ~s(aria-label="Fermix")
    assert body =~ "Main agent"
    assert body =~ "Health"
    assert body =~ "online"
    assert body =~ "Activity"
    assert body =~ "idle"
    assert body =~ "Subagents"
    assert body =~ "research"
    assert body =~ "Scheduled jobs"
    assert body =~ "Daily Digest"
    assert body =~ "gpt-5.4-mini"
    assert body =~ "Realtime voice"
    assert body =~ "gpt-realtime-2"
    assert body =~ "Active sessions"
    assert body =~ "realtime.sock"
    assert body =~ "Open setup"
    # F-1: the home page must NOT mint or embed a launch token.
    # The setup link is bare `/setup`; an unauthenticated visitor is refused by
    # SetupAuth (a launch token is only ever minted by the `fermix setup` CLI).
    assert setup_href = setup_href(body)
    assert setup_href == "/setup"
    refute setup_href =~ "t="
    assert body =~ ~s(href="/health/ready?pretty=1")
    assert body =~ ~s(href="/health/live?pretty=1")
    refute body =~ "Phoenix Framework"
    refute body =~ "Peace of mind from prototype to production"

    forbidden_conn = build_conn() |> get(setup_href)
    assert response(forbidden_conn, 403) =~ "setup authorization required"
    # The 403 is actionable: it names the one path that works.
    assert response(forbidden_conn, 403) =~ "fermix setup"
  end

  test "GET / renders a safe error when runtime snapshot fails", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
    Application.put_env(:fermix_web, :home_snapshot, BrokenHomeSnapshot)
    BootReport.refresh()

    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ "Runtime snapshot unavailable"
    assert body =~ "Runtime introspection is unavailable"
    refute body =~ "badmatch"
    refute body =~ "/Users/example"
    refute body =~ "#PID"
  end

  test "GET /setup renders actionable setup guidance when readiness is incomplete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)
    BootReport.refresh()

    conn = get(conn, ~p"/setup")
    body = html_response(conn, 200)

    assert body =~ "Setup required"
    assert body =~ "Provider"
    # The Provider tab carries the warning icon when provider config is missing.
    assert body =~ "text-warning"
  end

  test "GET /setup renders ready state when readiness is complete", %{conn: conn} do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
    BootReport.refresh()

    conn = get(conn, ~p"/setup")
    body = html_response(conn, 200)

    assert body =~ "Ready"
    assert body =~ "badge-success"
  end

  test "/ redirect and /health/ready honor BootReport cache; /setup always shows fresh state", %{
    conn: conn
  } do
    Application.put_env(:fermix_core, :providers, [])
    Application.delete_env(:fermix_channels, :telegram)
    BootReport.refresh()

    Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
    Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")

    # Home redirect uses the cached readiness, which still says setup_required.
    home_conn = get(conn, ~p"/")
    assert redirected_to(home_conn) == ~p"/setup"

    # /setup computes a fresh report on mount; the freshly satisfied config
    # surfaces as a Ready badge even though the BootReport cache is stale.
    setup_conn = home_conn |> recycle() |> get(~p"/setup")
    setup_body = html_response(setup_conn, 200)
    assert setup_body =~ "Ready"

    # /health/ready stays on the cache; the failures behind it are `Health.report/0`'s.
    ready_conn = setup_conn |> recycle() |> get(~p"/health/ready")
    ready_body = json_response(ready_conn, 503)

    assert ready_body["status"] == "setup_required"
    assert Enum.any?(Health.report().failures, &(&1.component == "provider:openai"))
  end

  # What the FakeHomeSnapshot dashboard shows: job, schedule, models, workers, paths.
  @dashboard_details [
    "Daily Digest",
    "daily_digest",
    "every 15 minutes",
    "gpt-5.4-mini",
    "gpt-realtime-2",
    "research",
    "session-1",
    "realtime.sock",
    "/Users/example"
  ]

  # F-02 of the M65 security review: a webhook tunnel forwards every path to the
  # loopback listener, so the dashboard answers only the setup session, however
  # the request arrives.
  describe "the setup session gates the dashboard" do
    setup do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "test-key"])
      Application.put_env(:fermix_channels, :telegram, bot_token: "bot-token")
      Application.put_env(:fermix_web, :home_snapshot, FakeHomeSnapshot)
      BootReport.refresh()
      :ok
    end

    test "an anonymous GET / is refused and names nothing the dashboard shows" do
      for conn <- [build_conn(), tunneled(build_conn())] do
        body = conn |> get(~p"/") |> response(403)

        assert body =~ "setup authorization required"
        assert body =~ "fermix setup"

        for detail <- @dashboard_details do
          refute body =~ detail
        end
      end
    end

    test "an authorized session renders the dashboard, tunneled or not", %{conn: conn} do
      for conn <- [conn, tunneled(conn)] do
        assert conn |> get(~p"/") |> html_response(200) =~ "Daily Digest"
      end
    end

    test "a launch token on / authorizes the session and lands on /setup" do
      {:ok, %{token: launch_token}} = AccessToken.mint_launch_token()

      conn = get(build_conn(), ~p"/?t=#{launch_token}")
      assert redirected_to(conn) == ~p"/setup"

      assert conn |> recycle() |> get(~p"/") |> html_response(200) =~ "Daily Digest"
    end

    # The `/live` socket never passes through the router's plugs, so the mount
    # makes the same check.
    test "a HomeLive mount without the setup session renders no snapshot", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/setup"}}} = live_isolated(build_conn(), HomeLive)

      assert {:ok, _view, html} = live_isolated(conn, HomeLive)
      assert html =~ "Daily Digest"
    end

    test "a socket that connects after the setup token rotated renders no snapshot", %{
      conn: conn
    } do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Daily Digest"

      assert {:ok, _token} = AccessToken.rotate_setup_token()

      assert {:error, {:redirect, %{to: "/setup"}}} = live(conn)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp setup_href(body) do
    case Regex.run(~r/<a[^>]+href="([^"]+)"[^>]*>\s*.*?Open setup/s, body) do
      [_, href] -> href
      nil -> nil
    end
  end
end
