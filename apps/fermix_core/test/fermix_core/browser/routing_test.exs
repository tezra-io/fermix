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
    {:ok, config} = Config.current(%{})
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
    :ok = HostAvailability.attached(host)
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

  defp route(ctx, owner, profile_name, profile, host) do
    Routing.for_request(owner, profile_name, profile, ctx.config, @context,
      registry: ctx.registry,
      host_availability: host
    )
  end

  test "a new browser use of fermix runs on the app's pane when its host is usable", ctx do
    assert {%{mode: :fermix_app} = profile, :fermix_app} =
             route(ctx, "owner-new", "fermix", @managed, host(:usable))

    assert Map.take(profile, [:headless, :cdp_port]) == %{headless: :auto, cdp_port: :auto}
  end

  test "with no usable host, fermix is the managed Chrome exactly as before", ctx do
    assert route(ctx, "owner-none", "fermix", @managed, host(:empty)) == {@managed, :cdp}

    attached = host(:empty)
    :ok = HostAvailability.listening(attached, endpoint())
    :ok = HostAvailability.attached(attached)
    assert route(ctx, "owner-silent", "fermix", @managed, attached) == {@managed, :cdp}

    :ok = HostAvailability.report(attached, false, "the pane is closed")
    assert route(ctx, "owner-busy", "fermix", @managed, attached) == {@managed, :cdp}
  end

  test "no profile but fermix is routed, whatever the host says", ctx do
    usable = host(:usable)

    profiles = %{
      "fermix_visible" => %{@managed | headless: false},
      "fermix_headless" => %{@managed | headless: true},
      "selected_tab" => %{mode: :attached_tab, headless: false, cdp_port: :auto},
      "mine" => %{mode: :existing_session, headless: :auto, cdp_port: :auto, cdp_url: "ws://x"}
    }

    for {name, profile} <- profiles do
      assert route(ctx, "owner-other", name, profile, usable) == {profile, :cdp},
             "`#{name}` was routed"
    end
  end

  # The decision is the live profile's, recorded when it started: a pane task
  # whose host has since gone is still a pane task (and fails there), and a
  # Chrome task stays in Chrome when a pane appears.
  test "a live profile pins every request to the backend it started on", ctx do
    :ok = live!(ctx.registry, "owner-pane", "fermix", :fermix_app)
    :ok = live!(ctx.registry, "owner-chrome", "fermix", :cdp)

    assert {%{mode: :fermix_app}, :fermix_app} =
             route(ctx, "owner-pane", "fermix", @managed, host(:empty))

    assert route(ctx, "owner-chrome", "fermix", @managed, host(:usable)) == {@managed, :cdp}
  end

  # End to end through the tool's own entry point and the browser tree's own
  # processes: decided at the start, kept while the profile lives, and a pane
  # that goes away fails its task and takes the profile with it.
  test "the facade decides at the start, keeps it, and reaps a lost pane" do
    host = HostAvailability
    endpoint = endpoint()
    :ok = HostAvailability.listening(host, endpoint)
    :ok = HostAvailability.attached(host)
    :ok = HostAvailability.report(host, true, nil)

    conversation = {"cli", "routing-#{System.unique_integer([:positive])}", :root}
    context = %{agent_name: "t", conversation_key: conversation}
    {:ok, owner} = Scope.owner_key(context)
    on_exit(fn -> ProfileManager.stop_owner(owner) end)

    assert {:error, %Error{code: "host_unavailable"}} =
             Browser.execute(%{"action" => "tabs"}, context)

    assert ProfileManager.backend(owner, "fermix") == :fermix_app

    :ok = HostAvailability.detached(host, "the app quit")

    assert {:error, %Error{code: "host_lost"} = error} =
             Browser.execute(%{"action" => "tabs"}, context)

    assert error.message =~ "no longer available: the app quit"
    assert eventually_reaped(owner)
  end

  defp eventually_reaped(owner, attempts \\ 40) do
    cond do
      ProfileManager.backend(owner, "fermix") == nil -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually_reaped(owner, attempts - 1)
    end
  end
end
