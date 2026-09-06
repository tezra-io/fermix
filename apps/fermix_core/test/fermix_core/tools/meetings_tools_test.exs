defmodule FermixCore.Tools.MeetingsToolsTest do
  # Not async: the meetings posture is global `Application` env, and each test
  # here establishes the posture it asserts against in its own setup rather
  # than reading whatever an earlier module left behind.
  use ExUnit.Case, async: false

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Capabilities.BuiltinSeeder
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Tools.JoinMeeting
  alias FermixCore.Tools.LeaveMeeting
  alias FermixCore.Tools.ListMeetings

  @attended %{source_trust: :operator, computer_use_origin: :interactive}

  @non_attended [
    {"guest trust", %{source_trust: :guest, computer_use_origin: :interactive}},
    {"scheduled run (no origin marker)", %{source_trust: :operator}},
    {"detached background run", %{source_trust: :operator, computer_use_origin: :unattended}},
    {"delegated subagent",
     %{source_trust: :operator, computer_use_origin: :interactive, subagent_depth: 1}},
    {"coding continuation",
     %{source_trust: :operator, computer_use_origin: :interactive, harness_continuation_depth: 1}},
    {"missing source_trust", %{computer_use_origin: :interactive}}
  ]

  # A complete Zoom credential set: the only lane that can be made ready
  # without touching the filesystem, so a "meetings are usable" posture costs
  # no fixture binary.
  @rtms_credentials [
    zoom_account_id: "acct",
    zoom_client_id: "client",
    zoom_client_secret: "secret",
    zoom_ws_subscription_id: "sub"
  ]

  setup do
    prev_meetings = Application.get_env(:fermix_core, :meetings)
    prev_plugins = Application.get_env(:fermix_core, :plugins)

    # `SidecarInstaller.installed?/0` prefers a dev_local build, so the Meet
    # lane is only reliably absent when dev_local is absent too.
    Application.put_env(:fermix_core, :plugins, [])

    on_exit(fn ->
      restore(:meetings, prev_meetings)
      restore(:plugins, prev_plugins)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)

  defp meetings(config), do: Application.put_env(:fermix_core, :meetings, config)

  defp base(extra),
    do: Map.merge(%{agent_name: "main", conversation_key: {"cli", "1", :root}}, extra)

  defp meetings_tools, do: BuiltinSeeder.meetings_tool_modules()

  defp start_repo do
    unique = System.unique_integer([:positive])
    db_path = Path.join(System.tmp_dir!(), "fermix-meetings-tools-#{unique}.db")
    repo_name = :"meetings_tools_repo_#{unique}"

    start_supervised!({Repo, name: repo_name, enabled: true, database_path: db_path})

    on_exit(fn ->
      Enum.each([db_path, "#{db_path}-wal", "#{db_path}-shm"], &FermixTestSupport.SafeRm.rm/1)
    end)

    repo_name
  end

  describe "the attended-owner gate" do
    for {label, context} <- @non_attended do
      test "no meetings tool advertises or runs on a #{label} turn" do
        context = base(unquote(Macro.escape(context)))

        for tool <- meetings_tools() do
          refute tool.advertise?(context),
                 "#{tool.name()} was advertised on a #{unquote(label)} turn"

          assert {:ok, result} = tool.execute(%{}, context)
          refute result.success, "#{tool.name()} executed on a #{unquote(label)} turn"
          assert result.error =~ tool.name()
        end
      end

      test "the provider-visible meetings surface on a #{label} turn is empty" do
        context = base(unquote(Macro.escape(context)))
        capabilities = Enum.map(meetings_tools(), &Builtin.from_tool_module/1)

        assert Advertisement.prepare(capabilities, context) == []
      end
    end

    test "an attended top-level operator turn advertises the whole family" do
      context = base(@attended)
      capabilities = Enum.map(meetings_tools(), &Builtin.from_tool_module/1)

      assert Enum.all?(meetings_tools(), & &1.advertise?(context))
      assert length(Advertisement.prepare(capabilities, context)) == length(meetings_tools())
    end
  end

  describe "policy classification" do
    setup do
      name = :"meetings_policy_reg_#{System.unique_integer([:positive])}"
      start_supervised!({CapabilityRegistry, name: name})

      for tool <- meetings_tools() do
        :ok = CapabilityRegistry.register(name, Builtin.from_tool_module(tool))
      end

      %{registry: name}
    end

    test "every meetings tool is external_api and owner-only" do
      for tool <- meetings_tools() do
        capability = Builtin.from_tool_module(tool)

        assert capability.policy_class == :external_api, tool.name()
        assert capability.owner_only? == true, tool.name()
        assert Builtin.owner_only_declared?(tool.name())
      end
    end

    test "a guest never sees a meetings tool", %{registry: registry} do
      names = registry |> CapabilityRegistry.list(trust: :guest) |> Enum.map(& &1.name)

      assert names == []
    end

    test "a nil trust collapses to the guest surface", %{registry: registry} do
      assert CapabilityRegistry.list(registry, trust: nil) == []
    end

    test "the operator sees all three", %{registry: registry} do
      names =
        registry
        |> CapabilityRegistry.list(trust: :operator)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert names == ["join_meeting", "leave_meeting", "list_meetings"]
    end
  end

  describe "join_meeting" do
    test "refuses with the disabled copy when meetings are off" do
      meetings(enabled: false)

      assert {:ok, result} =
               JoinMeeting.execute(
                 %{"url" => "https://meet.google.com/abc-defg-hij"},
                 base(@attended)
               )

      refute result.success
      assert result.error == JoinMeeting.describe_error(:meetings_disabled)
      assert result.error =~ "turned off"
    end

    test "refuses a link that is not a meeting" do
      meetings(enabled: true)

      assert {:ok, result} =
               JoinMeeting.execute(%{"url" => "https://example.com/standup"}, base(@attended))

      refute result.success
      assert result.error == JoinMeeting.describe_error(:unrecognized_meeting_url)
    end

    test "a Meet link with no sidecar renders the install copy verbatim" do
      meetings(enabled: true)

      assert {:ok, result} =
               JoinMeeting.execute(
                 %{"url" => "https://meet.google.com/abc-defg-hij"},
                 base(@attended)
               )

      refute result.success

      assert result.error ==
               "The Google Meet notetaker isn't installed yet. Enable the Meeting Notetaker " <>
                 "card on fermix setup (web) → Plugins to install the meetbot sidecar."
    end

    test "a Zoom link with no RTMS credentials renders the scope-honesty copy verbatim" do
      meetings(enabled: true)

      assert {:ok, result} =
               JoinMeeting.execute(%{"url" => "https://zoom.us/j/98765432101"}, base(@attended))

      refute result.success

      assert result.error ==
               "Zoom meetings use Zoom RTMS, which isn't configured. RTMS works for meetings " <>
                 "hosted by your own Zoom account (or a host who has enabled your RTMS app): " <>
                 "create a Zoom Server-to-Server OAuth app with RTMS scopes and set its " <>
                 "credentials in fermix setup (web) → Plugins → Meeting Notetaker → Configure. " <>
                 "Meetings hosted by other accounts can't be joined this way — that's a Zoom " <>
                 "platform limit, not a missing key."
    end

    # Only reachable with a meeting actually running, so the copy is asserted
    # against the renderer directly rather than left untested.
    test "the already-in-a-meeting copy names the meeting to leave" do
      assert JoinMeeting.describe_error({:max_concurrent, "mtg_9Xq2LmTfa0Q"}) ==
               "I'm already in a meeting (mtg_9Xq2LmTfa0Q). Ask me to leave it first — " <>
                 "I join one meeting at a time."
    end

    test "an unknown refusal is reported, never swallowed" do
      assert JoinMeeting.describe_error(:database_locked) =~ ":database_locked"
    end

    test "a missing url is a clean tool error" do
      meetings(enabled: true)

      assert {:ok, result} = JoinMeeting.execute(%{}, base(@attended))

      refute result.success
      assert result.error == "Missing required parameter: url"
    end
  end

  describe "leave_meeting" do
    setup do
      meetings([enabled: true] ++ @rtms_credentials)
      %{repo: start_repo()}
    end

    test "an unknown id says so", %{repo: repo} do
      context = base(Map.put(@attended, :memory_repo, repo))

      assert {:ok, result} = LeaveMeeting.execute(%{"id" => "mtg_missing"}, context)

      refute result.success
      assert result.error =~ "No meeting with that id"
    end

    test "a missing id is a clean tool error", %{repo: repo} do
      context = base(Map.put(@attended, :memory_repo, repo))

      assert {:ok, result} = LeaveMeeting.execute(%{}, context)

      refute result.success
      assert result.error == "Missing required parameter: id"
    end
  end

  describe "list_meetings" do
    setup do
      meetings([enabled: true] ++ @rtms_credentials)
      %{repo: start_repo()}
    end

    test "lists an empty recent scope by default", %{repo: repo} do
      context = base(Map.put(@attended, :memory_repo, repo))

      assert {:ok, result} = ListMeetings.execute(%{}, context)
      assert result.success, inspect(result)
      assert Jason.decode!(result.output) == %{"meetings" => []}
    end

    test "accepts the active scope", %{repo: repo} do
      context = base(Map.put(@attended, :memory_repo, repo))

      assert {:ok, result} = ListMeetings.execute(%{"scope" => "active"}, context)
      assert result.success, inspect(result)
      assert Jason.decode!(result.output) == %{"meetings" => []}
    end

    test "refuses a scope it does not know rather than guessing", %{repo: repo} do
      context = base(Map.put(@attended, :memory_repo, repo))

      assert {:ok, result} = ListMeetings.execute(%{"scope" => "everything"}, context)

      refute result.success
      assert result.error =~ "Invalid scope"
      assert result.error =~ "active, recent"
    end
  end
end
