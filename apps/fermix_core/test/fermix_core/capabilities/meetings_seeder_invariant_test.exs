defmodule FermixCore.Capabilities.MeetingsSeederInvariantTest do
  # Not async: the readiness posture is global `Application` env, established
  # per test and restored in `on_exit`.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Meetings

  # MILESTONE_21 C2 §14.1, written as the whole-surface invariant the AGENTS.md
  # gate-on-the-whole-feature pitfall mandates: when `Meetings.offered?/1` is
  # false, NO meetings tool is advertised. The assertion loops over the SEEDER's
  # family list and over everything the seeder actually registered, never over a
  # hand-written list of today's three tools, so a fourth meetings tool added
  # later either joins the invariant or fails it.
  #
  # The family is named by its object rather than by a prefix — `join_meeting`,
  # `leave_meeting`, `list_meetings` share no leading token — so the residue
  # check keys on the word "meeting" appearing anywhere in a registered name.
  @meeting_word "meeting"

  # A complete Zoom RTMS credential set makes the subsystem ready with no
  # filesystem state: the Meet lane needs an installed sidecar binary, which a
  # hermetic test has no business fabricating.
  @rtms_credentials [
    zoom_account_id: "acct",
    zoom_client_id: "client",
    zoom_client_secret: "secret",
    zoom_ws_subscription_id: "sub"
  ]

  setup do
    prev_meetings = Application.get_env(:fermix_core, :meetings)
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    # No dev_local root, so the Meet lane is definitively absent and every
    # "not ready" posture below is the posture it claims to be.
    Application.put_env(:fermix_core, :plugins, [])

    on_exit(fn ->
      restore(:meetings, prev_meetings)
      restore(:plugins, prev_plugins)
    end)

    registry = :"meetings_seeder_reg_#{System.unique_integer([:positive])}"
    start_supervised!({CapabilityRegistry, name: registry})

    %{registry: registry}
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp meetings(config), do: Application.put_env(:fermix_core, :meetings, config)

  # Whether this engine is an Always On server is the host's fact
  # (`Home.AlwaysOn.here?/0`), so every seed here states it.
  defp seed(registry, always_on_server),
    do:
      BuiltinSeeder.start_link(capability_registry: registry, always_on_server: always_on_server)

  defp registered_names(registry) do
    registry |> CapabilityRegistry.list() |> Enum.map(& &1.name)
  end

  defp assert_no_meetings_surface(registry, always_on_server \\ false) do
    :ignore = seed(registry, always_on_server)
    names = registered_names(registry)

    for tool <- BuiltinSeeder.meetings_tool_modules() do
      assert CapabilityRegistry.find(registry, tool.name()) == :error,
             "#{tool.name()} was seeded while meetings were not ready"
    end

    residue = Enum.filter(names, &String.contains?(&1, @meeting_word))
    assert residue == [], "meetings residue in the seeded surface: #{inspect(residue)}"

    # Sanity: the rest of the catalog still seeded, so an empty meetings
    # surface is a gate and not a seeder that did nothing.
    assert {:ok, _shell} = CapabilityRegistry.find(registry, "shell")
  end

  describe "no meetings tool is advertised when meetings are not offered" do
    test "meetings disabled (the default posture)", %{registry: registry} do
      meetings(enabled: false)

      refute Meetings.ready?()
      assert_no_meetings_surface(registry)
    end

    test "the config block is absent entirely", %{registry: registry} do
      Application.delete_env(:fermix_core, :meetings)

      refute Meetings.ready?()
      assert_no_meetings_surface(registry)
    end

    # The headless-enable rule: flipping the toggle without installing a lane
    # must seed nothing, or the model is handed a notetaker that refuses every
    # URL it is given.
    test "enabled but no lane is installed or configured", %{registry: registry} do
      meetings(enabled: true)

      refute Meetings.ready?()
      assert_no_meetings_surface(registry)
    end

    test "enabled with a half-configured Zoom credential set", %{registry: registry} do
      meetings([enabled: true] ++ Keyword.delete(@rtms_credentials, :zoom_client_secret))

      refute Meetings.ready?()
      assert_no_meetings_surface(registry)
    end

    # An unresolved `@keyring` secret is a credential that never arrived, not a
    # configured one; readiness must read it as absent.
    test "enabled with an unresolved keyring secret", %{registry: registry} do
      meetings([enabled: true] ++ Keyword.put(@rtms_credentials, :zoom_client_secret, "@keyring"))

      refute Meetings.ready?()
      assert_no_meetings_surface(registry)
    end
  end

  describe "a ready daemon seeds the whole family" do
    setup %{registry: registry} do
      meetings([enabled: true] ++ @rtms_credentials)
      assert Meetings.ready?()
      :ignore = seed(registry, false)
      :ok
    end

    test "every family member is registered with its explicit classification", %{
      registry: registry
    } do
      for tool <- BuiltinSeeder.meetings_tool_modules() do
        assert {:ok, capability} = CapabilityRegistry.find(registry, tool.name())
        assert capability.policy_class == :external_api, tool.name()
        assert capability.owner_only? == true, tool.name()
        assert capability.kind == :builtin
      end
    end

    test "the seeded meetings residue is exactly the family", %{registry: registry} do
      seeded =
        registry
        |> registered_names()
        |> Enum.filter(&String.contains?(&1, @meeting_word))
        |> Enum.sort()

      expected = BuiltinSeeder.meetings_tool_modules() |> Enum.map(& &1.name()) |> Enum.sort()

      assert seeded == expected
    end
  end

  # M102 N6, D5: on an Always On server the family is registered once meetings
  # are on, with no lane usable there, so a Meet link reaches the server's own
  # sentence (`Meetings.meet_here/1`) instead of finding no meeting tool and
  # going to a browser. `ready?/1` is unchanged: it is what Doctor and setup
  # report.
  describe "on an Always On server" do
    test "meetings on and no Zoom seeds the family, and a Meet link hears why", %{
      registry: registry
    } do
      meetings(enabled: true)

      :ignore = seed(registry, true)

      for tool <- BuiltinSeeder.meetings_tool_modules() do
        assert {:ok, _capability} = CapabilityRegistry.find(registry, tool.name()),
               "#{tool.name()} was not seeded on a server with meetings on"
      end

      {:ok, join} = CapabilityRegistry.find(registry, "join_meeting")

      context = %{
        source_trust: :operator,
        computer_use_origin: :interactive,
        meetings_opts: [always_on_server: true]
      }

      assert {:ok, result} =
               Capability.execute(
                 join,
                 %{"url" => "https://meet.google.com/abc-defg-hij"},
                 context
               )

      refute result.success
      assert result.error == Meetings.meet_unavailable_sentence(false)
    end

    test "meetings off seeds nothing there either", %{registry: registry} do
      meetings(enabled: false)

      refute Meetings.offered?(always_on_server: true)
      assert_no_meetings_surface(registry, true)
    end

    test "offered there is not ready there: Doctor and setup still say no lane is usable" do
      meetings(enabled: true)

      assert Meetings.offered?(always_on_server: true)
      refute Meetings.ready?(always_on_server: true)
      refute Meetings.offered?(always_on_server: false)
    end
  end

  describe "family membership" do
    test "every member is in the classification-coverage list unconditionally" do
      coverage = BuiltinSeeder.builtin_tool_modules()

      for tool <- BuiltinSeeder.meetings_tool_modules() do
        assert tool in coverage
        assert tool.name() in Builtin.classified_names()
        assert function_exported?(tool, :advertise?, 1)
      end
    end

    # The other direction: a meetings tool added to the coverage list but not to
    # the family list would sit outside the readiness gate entirely.
    test "no built-in named for a meeting is missing from the family list" do
      named =
        BuiltinSeeder.builtin_tool_modules()
        |> Enum.filter(&String.contains?(&1.name(), @meeting_word))
        |> Enum.sort()

      assert named == Enum.sort(BuiltinSeeder.meetings_tool_modules())
    end
  end
end
