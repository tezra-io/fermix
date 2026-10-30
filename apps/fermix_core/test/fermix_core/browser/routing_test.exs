defmodule FermixCore.Browser.RoutingTest do
  # Sync: the last test drives the browser tree's own availability process and
  # profile registry, so no other module may route while it holds a host.
  use ExUnit.Case, async: false

  alias FermixCore.Browser
  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.HostAvailability
  alias FermixCore.Browser.ProfileManager
  alias FermixCore.Browser.Routing
  alias FermixCore.Browser.Scope

  @managed %{mode: :managed, headless: :auto, cdp_port: :auto}
  @context %{agent_name: "t"}

  setup do
    # A short deadline: a host that attached and has not reported is waited for.
    {:ok, config} = Config.current(%{host_launch_timeout_ms: 50, wait_poll_interval_ms: 10})
    registry = Module.concat(__MODULE__, "Registry#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :unique, name: registry}, id: registry)
    %{config: config, registry: registry}
  end

  defp endpoint do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp host(:usable) do
    host = host(:empty)
    :ok = HostAvailability.listening(host, endpoint())
    :ok = HostAvailability.attached(host, endpoint(), 1)
    :ok = HostAvailability.report(host, true, nil)
    host
  end

  defp host(:empty), do: start_supervised!({HostAvailability, name: nil}, id: make_ref())

  # A live profile as the registry records it: `{last_used, backend}`.
  defp live!(registry, owner, profile_name, backend) do
    name = {:via, Registry, {registry, {owner, profile_name}, {0, backend}}}

    start_supervised!(%{
      id: make_ref(),
      start: {Agent, :start_link, [fn -> :live end, [name: name]]}
    })

    :ok
  end

  # The keys a conversation's browser can live under: the scope's shared
  # profile, and the conversation's own pane profile.
  defp keys(owner, pane \\ nil), do: %{owner: owner, pane: pane || owner <> "-pane"}

  defp route(ctx, keys, profile_name, profile, host) when is_map(keys) do
    Routing.for_request(keys, profile_name, profile, ctx.config, @context,
      registry: ctx.registry,
      host_availability: host
    )
  end

  defp route(ctx, owner, profile_name, profile, host),
    do: route(ctx, keys(owner), profile_name, profile, host)

  test "fermix and fermix_visible both run on the app's pane when its host is usable", ctx do
    profiles = %{"fermix" => @managed, "fermix_visible" => %{@managed | headless: false}}

    for {name, profile} <- profiles do
      pane = "owner-new-#{name}-pane"

      assert {%{mode: :fermix_app} = routed, :fermix_app, ^pane} =
               route(ctx, "owner-new-#{name}", name, profile, host(:usable))

      assert Map.take(routed, [:headless, :cdp_port]) == Map.take(profile, [:headless, :cdp_port]),
             "`#{name}` lost its own headless/cdp_port"
    end
  end

  test "a new browser use opens the app when launching is on, then runs on its pane", ctx do
    {:ok, config} = Config.current(%{launch_app: true, host_launch_timeout_ms: 50})
    pane = host(:empty)
    :ok = HostAvailability.listening(pane, endpoint())
    test = self()

    launcher = fn _timeout_ms ->
      send(test, :opened)
      :ok = HostAvailability.attached(pane, endpoint(), 1)
      HostAvailability.report(pane, true, nil)
    end

    assert {%{mode: :fermix_app}, :fermix_app, "owner-open-pane"} =
             Routing.for_request(keys("owner-open"), "fermix", @managed, config, @context,
               registry: ctx.registry,
               host_availability: pane,
               launcher: launcher
             )

    assert_received :opened
  end

  test "with no usable host, fermix and fermix_visible are the managed Chrome exactly as before",
       ctx do
    profiles = %{"fermix" => @managed, "fermix_visible" => %{@managed | headless: false}}

    for {name, profile} <- profiles do
      assert route(ctx, "owner-none-#{name}", name, profile, host(:empty)) ==
               {profile, :cdp, "owner-none-#{name}"}
    end

    attached = host(:empty)
    :ok = HostAvailability.listening(attached, endpoint())
    :ok = HostAvailability.attached(attached, endpoint(), 1)

    for {name, profile} <- profiles do
      assert route(ctx, "owner-silent-#{name}", name, profile, attached) ==
               {profile, :cdp, "owner-silent-#{name}"}
    end

    :ok = HostAvailability.report(attached, false, "the pane is closed")

    for {name, profile} <- profiles do
      assert route(ctx, "owner-busy-#{name}", name, profile, attached) ==
               {profile, :cdp, "owner-busy-#{name}"}
    end
  end

  test "no profile but fermix and fermix_visible are routed, whatever the host says", ctx do
    usable = host(:usable)

    profiles = %{
      "fermix_headless" => %{@managed | headless: true},
      "selected_tab" => %{mode: :attached_tab, headless: false, cdp_port: :auto},
      "mine" => %{mode: :existing_session, headless: :auto, cdp_port: :auto, cdp_url: "ws://x"}
    }

    for {name, profile} <- profiles do
      assert route(ctx, "owner-other", name, profile, usable) == {profile, :cdp, "owner-other"},
             "`#{name}` was routed"
    end
  end

  # The profile for what only Chrome can do, as it is configured: a usable pane
  # does not take it, and no app is opened for it, so a page's WebMCP tools are
  # always one `profile: "fermix_chrome"` away.
  test "fermix_chrome is the managed Chrome beside a usable pane, and opens no app", ctx do
    {:ok, config} = Config.current(%{launch_app: true, host_launch_timeout_ms: 50})
    {:ok, profile, "fermix_chrome"} = Config.profile(config, "fermix_chrome")
    test = self()
    launcher = fn _timeout_ms -> send(test, :opened) end

    listening = host(:empty)
    :ok = HostAvailability.listening(listening, endpoint())

    for host <- [host(:usable), listening] do
      assert Routing.for_request(keys("owner-chrome"), "fermix_chrome", profile, config, @context,
               registry: ctx.registry,
               host_availability: host,
               launcher: launcher
             ) == {profile, :cdp, "owner-chrome"}
    end

    refute_received :opened
  end

  # The decision is the live profile's, recorded when it started: a pane task
  # whose host has since gone is still a pane task (and fails there), and a
  # Chrome task stays in Chrome when a pane appears.
  test "a live profile pins every request to the backend it started on", ctx do
    :ok = live!(ctx.registry, "owner-pane-pane", "fermix", :fermix_app)
    :ok = live!(ctx.registry, "owner-chrome", "fermix", :cdp)

    assert {%{mode: :fermix_app}, :fermix_app, "owner-pane-pane"} =
             route(ctx, "owner-pane", "fermix", @managed, host(:empty))

    assert route(ctx, "owner-chrome", "fermix", @managed, host(:usable)) ==
             {@managed, :cdp, "owner-chrome"}
  end

  # A pane task belongs to the conversation that started it and ends with its
  # turn, so the pane is the conversation's own; Chrome is the owner's one
  # browser. A conversation is pinned to its own live pane profile first, then
  # to the owner's live Chrome, and only then decided fresh.
  test "a conversation's own live pane comes first, then the owner's live Chrome, then a fresh decision",
       ctx do
    chat_a = keys("owner-shared", "pane-a")
    chat_b = keys("owner-shared", "pane-b")
    :ok = live!(ctx.registry, "pane-a", "fermix", :fermix_app)

    # A keeps its pane even with no usable host (and fails there, not in Chrome).
    assert {%{mode: :fermix_app}, :fermix_app, "pane-a"} =
             route(ctx, chat_a, "fermix", @managed, host(:empty))

    # B has no pane of its own: decided fresh, onto its own pane, never A's.
    assert {%{mode: :fermix_app}, :fermix_app, "pane-b"} =
             route(ctx, chat_b, "fermix", @managed, host(:usable))

    # Once the owner's Chrome is live, a conversation without a pane joins it.
    :ok = live!(ctx.registry, "owner-shared", "fermix", :cdp)

    assert route(ctx, chat_b, "fermix", @managed, host(:usable)) ==
             {@managed, :cdp, "owner-shared"}

    assert {%{mode: :fermix_app}, :fermix_app, "pane-a"} =
             route(ctx, chat_a, "fermix", @managed, host(:usable))
  end

  test "two owner conversations decided onto Chrome both run in the owner's one profile", ctx do
    for pane <- ["pane-c", "pane-d"] do
      assert route(ctx, keys("owner-one", pane), "fermix", @managed, host(:empty)) ==
               {@managed, :cdp, "owner-one"}
    end
  end

  # A guest's pane and Chrome are both its conversation's one profile, as they
  # always were.
  test "a guest's conversation has one key for both backends", ctx do
    guest = keys("guest-x", "guest-x")
    :ok = live!(ctx.registry, "guest-x", "fermix", :cdp)
    assert route(ctx, guest, "fermix", @managed, host(:usable)) == {@managed, :cdp, "guest-x"}

    pane_guest = keys("guest-y", "guest-y")
    :ok = live!(ctx.registry, "guest-y", "fermix", :fermix_app)

    assert {%{mode: :fermix_app}, :fermix_app, "guest-y"} =
             route(ctx, pane_guest, "fermix", @managed, host(:empty))
  end

  test "live/3 names the profile a conversation is pinned to, deciding nothing", ctx do
    :ok = live!(ctx.registry, "pane-live", "fermix", :fermix_app)
    :ok = live!(ctx.registry, "owner-live", "fermix", :cdp)
    opts = [registry: ctx.registry]

    assert Routing.live(keys("owner-live", "pane-live"), "fermix", opts) ==
             {"pane-live", :fermix_app}

    assert Routing.live(keys("owner-live", "pane-other"), "fermix", opts) == {"owner-live", :cdp}
    assert Routing.live(keys("owner-none", "pane-none"), "fermix", opts) == nil
  end

  # End to end through the tool's own entry point and the browser tree's own
  # processes: decided at the start, kept while the profile lives, a pane that
  # goes away fails its task and takes the profile with it, and the turn that
  # saw the loss answers the same sentence for the rest of the turn instead of
  # being routed to Chrome (`TurnMarker`).
  test "the facade decides at the start, keeps it, reaps a lost pane, and marks the turn" do
    host = HostAvailability
    endpoint = endpoint()

    {:ok, connection} =
      FermixTestSupport.FakeBrowserHostConnection.start_link(%{
        "tab.list" => {:ok, %{"tabs" => []}}
      })

    on_exit(fn -> Process.exit(connection, :kill) end)
    :ok = HostAvailability.listening(host, endpoint)
    :ok = HostAvailability.attached(host, connection, 1)
    :ok = HostAvailability.report(host, true, nil)

    # A guest's call, so its profile is this conversation's own: every owner
    # call shares the one "owner" profile, which another test may have running.
    conversation = {"cli", "routing-#{System.unique_integer([:positive])}", :root}
    context = %{agent_name: "t", conversation_key: conversation, source_trust: :guest}
    {:ok, owner} = Scope.owner_key(context)
    on_exit(fn -> ProfileManager.stop_owner(owner) end)

    assert {{:ok, encoded}, :fermix_app} = Browser.execute(%{"action" => "tabs"}, context)
    assert Jason.decode!(encoded) == %{"ok" => true, "tabs" => []}
    assert ProfileManager.backend(owner, "fermix") == :fermix_app

    Process.exit(connection, :kill)

    assert {{:error, %Error{code: "host_lost"} = error}, :fermix_app} =
             Browser.execute(%{"action" => "tabs"}, context)

    assert error.message =~ "no longer available: the app disconnected"
    assert eventually_reaped(owner)

    assert {{:error, ^error}, :fermix_app} = Browser.execute(%{"action" => "tabs"}, context)
    assert ProfileManager.backend(owner, "fermix") == nil
  end

  defp eventually_reaped(owner, attempts \\ 40) do
    cond do
      ProfileManager.backend(owner, "fermix") == nil -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually_reaped(owner, attempts - 1)
    end
  end
end
