defmodule FermixCore.Home.MoveReadinessTest do
  # Every fact comes from the home on disk and seams: the free space, this
  # engine's version and host. The keychain is the stub store, under a
  # profile of this test's own.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.MoveReadiness
  alias FermixCore.Home.Releases
  alias FermixCore.Setup.MachineFile
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.DistFixtures
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @desktop_id "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @plenty 1_099_511_627_776

  setup do
    home = SafeRm.make_tmp_dir!("move_readiness")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 4)
    profile = "ready-#{System.unique_integer([:positive])}"

    File.write!(Path.join(home, "config.toml"), """
    [fermix_core]
    profile = "#{profile}"

    [fermix_core.providers.anthropic]
    api_key = "@keyring"

    [fermix_channels.whatsapp]
    enabled = true

    [fermix_channels.slack]
    enabled = true

    [fermix_core.meetings]
    enabled = true

    [fermix_channels.imessage]
    enabled = true
    """)

    # This Mac's own settings (M97 §4): it carries Messages, which the home
    # uses (config.toml's [fermix_channels.imessage], the home's own), and
    # coding agents may run on it (M98 D5).
    File.write!(MachineFile.path(home), """
    [fermix_core.computer]
    imessage = true

    [fermix_core.harness]
    approved = true
    """)

    File.mkdir_p!(Path.join(home, "plugins"))

    File.write!(
      Path.join(home, "plugins/installed.json"),
      ~s({"invented-notes": {"version": "1.0.0"}, "invented-tasks": {"version": "2.1.0"}})
    )

    # The catalog this engine ships: invented-notes is built for this Mac
    # only, invented-tasks for any system.
    index =
      DistFixtures.write_index(Path.join(home, "catalog/index.json"), [
        catalog_entry("invented-notes", "1.0.0", ["macos-aarch64"]),
        catalog_entry("invented-tasks", "2.1.0", ["any"])
      ])

    {:ok, candidate} = Candidates.add(home, candidate_attrs(), @now)
    %{home: home, candidate: candidate, profile: profile, index: index}
  end

  test "a ready move: the keychain's secret can be read, and every warning is said", ctx do
    :ok =
      SecretWriter.put(:anthropic_api_key, "sk-ant-invented",
        profile: ctx.profile,
        store: :keyring
      )

    assert %{ready: true, items: items} =
             MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert Enum.map(items, &{&1.id, &1.status}) == [
             {"keychain_secrets", :ok},
             {"engine_version", :ok},
             {"disk", :ok},
             {"s3_size", :ok},
             {"plugins", :warn},
             {"stays_here", :warn},
             {"whatsapp", :warn},
             {"slack", :warn},
             {"coding_agents", :warn},
             {"settings", :ok},
             {"cutover_gap", :warn},
             {"serves_nothing", :warn},
             {"service", :ok}
           ]

    sentence = fn id -> Enum.find(items, &(&1.id == id)).sentence end
    assert sentence.("keychain_secrets") =~ "1 secret kept in this computer's keychain moves"
    # Reading it can raise the keychain's own prompt, here and once more when
    # the move carries it.
    assert sentence.("keychain_secrets") =~
             "Checking it opened this computer's keychain, and the move opens it once more"

    # Only the plugin with no build for the server is named: the server
    # installs the others again itself.
    assert sentence.("plugins") ==
             "These plugins have no build for north-box, so they stop working after the " <>
               "move: invented-notes."

    assert sentence.("engine_version") ==
             "north-box runs a Fermix that reads this home, and this computer could read it back."

    # Only what this home uses of what runs here alone is named. iMessage is
    # not: after the move this Mac carries it for north-box (M97 §6.4).
    assert sentence.("stays_here") ==
             "Meetings stop after the move: neither this Mac nor north-box runs them."

    # The server reaches the internet for WhatsApp only through a Funnel
    # mount, whose command Always On shows once Fermix runs there, and Meta
    # posts to the old address until it is pointed at the new one (review F8).
    assert sentence.("whatsapp") ==
             "WhatsApp stops after the move until you run the Tailscale Funnel command " <>
               "Always On shows for north-box and point Meta at the address it prints."

    assert sentence.("slack") ==
             "Slack stops after the move unless it uses Socket Mode, which you turn on in " <>
               "your Slack app's settings and then in Fermix's Slack settings."

    # M98 D5: the approval is this Mac's and stays here; the server's own
    # decides there.
    assert sentence.("coding_agents") ==
             "Coding agents stop on this Mac after the move. They run on north-box only " <>
               "with your approval there. To run them on north-box too, allow them there in " <>
               "Settings, Coding agents, after the move."

    # M97 D28 (§19.8): after the move the apps' Settings change the server.
    assert sentence.("settings") ==
             "After the move, Settings in this app change Fermix on north-box, its sandbox and " <>
               "coding agents included. A new server's sandbox starts Open. What north-box may " <>
               "use on this Mac, and this Mac's own sandbox, are under This Mac."

    # This home sets up no Telegram, so the gap names only the jobs (EC2 test
    # finding 7).
    assert sentence.("cutover_gap") ==
             "A recurring job more than an hour late while the move runs is skipped."

    assert sentence.("serves_nothing") =~ "north-box"
    refute Enum.any?(items, &(&1.sentence =~ "sk-ant-invented"))
  end

  test "WhatsApp and Slack turned off, Slack on Socket Mode, and no coding agent approved say so",
       ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_channels.whatsapp]
    enabled = false

    [fermix_channels.slack]
    enabled = true
    mode = "socket"
    """)

    File.write!(MachineFile.path(ctx.home), "")

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
    item = fn id -> Enum.find(items, &(&1.id == id)) end

    assert %{status: :ok, sentence: "WhatsApp is not turned on."} = item.("whatsapp")

    assert %{status: :ok, sentence: "Slack uses Socket Mode and keeps working on north-box."} =
             item.("slack")

    assert %{status: :ok, sentence: "No coding agent has your approval on this computer."} =
             item.("coding_agents")

    assert %{status: :ok, sentence: "Voice calls and meetings are not turned on."} =
             item.("stays_here")

    File.write!(Path.join(ctx.home, "config.toml"), "")
    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
    assert %{status: :ok, sentence: "Slack is not turned on."} = item_in(items, "slack")
  end

  # Telegram keeps what it holds until the poller asks again, so its messages
  # wait out the move; the gap names Telegram only while it is set up: turned
  # on (its shipped default) with a bot token (EC2 test finding 7).
  test "the cutover gap names Telegram only while this home has it set up", ctx do
    telegram =
      "Messages sent to Telegram while the move runs wait until it is done, and a " <>
        "recurring job more than an hour late is skipped."

    jobs = "A recurring job more than an hour late while the move runs is skipped."

    for {settings, said} <- [
          {~s([fermix_channels.telegram]\nenabled = true\nbot_token = "@keyring"\n), telegram},
          {~s([fermix_channels.telegram]\nbot_token = "123456:invented"\n), telegram},
          {~s([fermix_channels.telegram]\nenabled = false\nbot_token = "@keyring"\n), jobs},
          {"[fermix_channels.telegram]\nenabled = true\n", jobs},
          {~s([fermix_channels.telegram]\nenabled = true\nbot_token = ""\n), jobs},
          {"", jobs}
        ] do
      items = MoveReadiness.summary_items({:ok, settings}, true, "north-box", opts(ctx))
      assert %{status: :warn, sentence: ^said} = item_in(items, "cutover_gap")
    end
  end

  # What a move back costs that its confirm names: only what the settings
  # turn on (EC2 test finding 15). Coding agents cost nothing: this computer
  # kept its own approval in its machine file (M98 D5).
  test "the costs a confirm names are what the settings turn on, and none unread" do
    assert MoveReadiness.costs({:ok, ""}) == []
    assert MoveReadiness.costs({:error, "The settings file could not be read."}) == []

    assert MoveReadiness.costs(
             {:ok,
              "[fermix_core.harness]\napproved = true\n\n" <>
                ~s([fermix_channels.telegram]\nbot_token = "@keyring"\n)}
           ) == [:telegram]

    assert MoveReadiness.costs(
             {:ok,
              ~s([fermix_core.harness]\napproved = true\n\n[fermix_channels.telegram]\nenabled = false\nbot_token = "@keyring"\n)}
           ) == []
  end

  # The approval is read from this computer's machine file alone: a copy
  # written into config.toml by hand is read by nothing (M98 D5).
  test "a coding approval left in config.toml is not this computer's", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), "[fermix_core.harness]\napproved = true\n")
    File.write!(MachineFile.path(ctx.home), "[fermix_core.harness]\napproved = false\n")

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert %{status: :ok, sentence: "No coding agent has your approval on this computer."} =
             item_in(items, "coding_agents")
  end

  # On a computer that is no Mac, the machine is named as one.
  test "the review names the computer that is no Mac", ctx do
    settings = {:ok, "[fermix_core.harness]\napproved = true\n"}

    assert %{status: :warn, sentence: sentence} =
             item_in(
               MoveReadiness.summary_items(settings, false, "north-box", opts(ctx)),
               "coding_agents"
             )

    assert sentence ==
             "Coding agents stop on this computer after the move. They run on north-box only " <>
               "with your approval there. To run them on north-box too, allow them there in " <>
               "Settings, Coding agents, after the move."

    assert %{status: :ok, sentence: said} =
             item_in(
               MoveReadiness.summary_items(settings, false, "north-box", opts(ctx)),
               "settings"
             )

    assert said =~
             "What north-box may use on this computer, and this computer's own sandbox, " <>
               "are under This computer."
  end

  test "plugins with a build for the server are installed again there, and say so", ctx do
    File.write!(
      Path.join(ctx.home, "plugins/installed.json"),
      ~s({"invented-tasks": {"version": "2.1.0"}})
    )

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert %{status: :ok, sentence: "north-box installs the plugins again for itself right " <> _} =
             item_in(items, "plugins")

    # A plugin the catalog does not carry, or carries in another version, has
    # no build Fermix can install there either.
    File.write!(
      Path.join(ctx.home, "plugins/installed.json"),
      ~s({"invented-tasks": {"version": "9.9.9"}, "invented-local": {"version": "1.0.0"}})
    )

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
    assert %{status: :warn, sentence: sentence} = item_in(items, "plugins")
    assert sentence =~ "move: invented-local, invented-tasks."
  end

  test "blocks: an unreadable secret named, an older server, a disk with no room", ctx do
    old = %{ctx.candidate | version: "0.0.1"}
    tight = Keyword.put(opts(ctx), :free_bytes, fn _dir -> {:ok, 1_000} end)

    assert %{ready: false, items: items} = MoveReadiness.report(ctx.home, old, tight)
    blocks = for %{status: :block} = item <- items, do: {item.id, item.sentence}

    assert [
             {"keychain_secrets", secrets},
             {"engine_version", version},
             {"disk", disk}
           ] = blocks

    assert secrets ==
             "The keychain did not give Fermix your Anthropic key: unlock it, or set it " <>
               "again or clear it in settings, then check again."

    assert version =~ "north-box runs an older Fermix"
    assert disk =~ "make room first"
  end

  # M97 §3.4, D16: whether the home could come back here is its format,
  # never the server's version. A newer server in this computer's format is
  # fine with nothing read; one in a newer format is fine once a published
  # update for this computer's system reads it, read from the release table
  # at the review; until then, or with the table unread, it blocks: the
  # home could never come back here.
  test "a newer server in this computer's home format is fine, with no table read", ctx do
    refuse = fn -> flunk("the table is read only for a home this computer cannot read") end
    newer = %{ctx.candidate | version: "0.19.0"} |> Map.put(:home_format, 3)
    seams = Keyword.merge(opts(ctx), release_table: refuse, home_format: 3)

    assert %{items: items} = MoveReadiness.report(ctx.home, newer, seams)

    assert item_in(items, "engine_version") == %{
             id: "engine_version",
             status: :ok,
             sentence:
               "north-box runs a Fermix that reads this home, and this computer could read it back."
           }
  end

  test "a server in a newer home format is fine once this computer's update is published, " <>
         "and blocks before",
       ctx do
    newer = %{ctx.candidate | version: "0.18.0"} |> Map.put(:home_format, 2)
    seams = Keyword.put(opts(ctx), :home_format, 1)
    table = fn rows -> fn -> Releases.parse(release_table(rows)) end end

    for rows <- [
          ["app 0.18.0 macos 2.4.0"],
          ["app 0.17.0 macos 2.3.0", "home_format 0.17.0 2", "home_format 0.18.0 2"]
        ] do
      published = Keyword.put(seams, :release_table, table.(rows))
      assert %{items: items} = MoveReadiness.report(ctx.home, newer, published)
      assert %{status: :ok, sentence: sentence} = item_in(items, "engine_version")

      assert sentence ==
               "north-box runs a newer Fermix than this computer. The update for this " <>
                 "computer is published: install it before you move Fermix back here."
    end

    # Only the Linux app reads it, and this computer is a Mac; or the Mac's
    # app is in the older format.
    for rows <- [
          ["app 0.18.0 linux 1.3.0"],
          ["app 0.17.0 macos 2.3.0", "home_format 0.17.0 1", "home_format 0.18.0 2"]
        ] do
      unpublished = Keyword.put(seams, :release_table, table.(rows))
      assert %{ready: false, items: items} = MoveReadiness.report(ctx.home, newer, unpublished)
      assert %{status: :block, sentence: sentence} = item_in(items, "engine_version")

      assert sentence ==
               "north-box runs a newer Fermix than this computer, and no update for this " <>
                 "computer reads its home yet, so Fermix could not move back. Set the server " <>
                 "up with this computer's version, or wait for that update."
    end

    unread = Keyword.put(seams, :release_table, fn -> {:error, "An invented failure."} end)
    assert %{ready: false, items: items} = MoveReadiness.report(ctx.home, newer, unread)
    assert %{status: :block, sentence: sentence} = item_in(items, "engine_version")
    assert sentence =~ "Fermix could not read which updates are published. Check again."
  end

  # A server whose Fermix names a home format below this home's cannot read
  # it, whatever its version; one from before formats reads by version.
  test "a server that cannot read this home's format blocks, whatever its version", ctx do
    seams = Keyword.put(opts(ctx), :home_format, 2)
    behind = %{ctx.candidate | version: "0.20.0"} |> Map.put(:home_format, 1)

    assert %{ready: false, items: items} = MoveReadiness.report(ctx.home, behind, seams)
    assert %{status: :block, sentence: sentence} = item_in(items, "engine_version")

    assert sentence ==
             "north-box runs an older Fermix than this computer, one that cannot read this " <>
               "home: update Fermix on north-box first, then check again."
  end

  # The same review on the server, when the candidate is the desktop the
  # home left (it enrolled through the window that desktop opened to move
  # back): what stops on a server runs there again, and a desktop newer than
  # the server takes the home as any newer engine takes an older one's. The
  # direction is that fact, never the candidate's system: a Linux desktop
  # moving back is a move back, and a Mac enrolled through any other window
  # is not.
  test "moving back to the desktop the home left: what the server leaves off runs there " <>
         "again, and only an older desktop blocks",
       ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_core.realtime]
    enabled = true

    [fermix_core.meetings]
    enabled = true
    """)

    back = Map.merge(candidate_attrs(), %{name: "studio-box", returning: @desktop_id})
    {:ok, desktop} = Candidates.add(ctx.home, back, @now)

    server = Keyword.merge(opts(ctx), host: "linux-x86_64", version: "0.17.0")
    newer = %{desktop | version: "0.18.0"}

    assert %{items: items} = MoveReadiness.report(ctx.home, newer, server)

    assert %{
             status: :ok,
             sentence: "Voice calls and meetings run on studio-box again after the move."
           } =
             item_in(items, "stays_here")

    assert %{status: :ok, sentence: "studio-box runs a Fermix that reads this home."} =
             item_in(items, "engine_version")

    # A move back makes the desktop its own home again: no app's Settings
    # change the server after it (M97 D28, §19.8).
    assert item_in(items, "settings") == nil

    # An engine before home formats reads by its version, so an older one
    # blocks; an older one that reads the server's home format does not
    # (M97 D16), and one whose format is below it does.
    older = %{desktop | version: "0.16.0"}
    assert %{ready: false, items: items} = MoveReadiness.report(ctx.home, older, server)
    assert %{status: :block, sentence: sentence} = item_in(items, "engine_version")

    assert sentence =~
             "studio-box runs an older Fermix than this computer, one that cannot read this " <>
               "home: update Fermix on"

    same_format = Map.put(older, :home_format, 2)
    formatted = Keyword.put(server, :home_format, 2)
    assert %{items: items} = MoveReadiness.report(ctx.home, same_format, formatted)
    assert %{status: :ok} = item_in(items, "engine_version")

    below = Map.put(older, :home_format, 1)
    assert %{ready: false, items: items} = MoveReadiness.report(ctx.home, below, formatted)
    assert %{status: :block} = item_in(items, "engine_version")

    File.write!(Path.join(ctx.home, "config.toml"), "")
    assert %{items: items} = MoveReadiness.report(ctx.home, newer, server)

    assert %{status: :ok, sentence: "Voice calls and meetings are not turned on."} =
             item_in(items, "stays_here")
  end

  test "a Mac that enrolled through any other window is a move to a server, not back",
       ctx do
    {:ok, mac} =
      Candidates.add(ctx.home, %{candidate_attrs() | name: "studio-mac", os: "darwin"}, @now)

    unread = Keyword.put(opts(ctx), :release_table, fn -> {:error, "An invented failure."} end)

    newer = mac |> Map.put(:version, "0.18.0") |> Map.put(:home_format, 2)

    assert %{ready: false, items: items} =
             MoveReadiness.report(ctx.home, newer, Keyword.put(unread, :home_format, 1))

    assert %{status: :block, sentence: sentence} = item_in(items, "engine_version")
    assert sentence =~ "studio-mac runs a newer Fermix than this computer"
  end

  # M87: a move restarts this engine, which ends a call in progress before the
  # move starts; the review says so, naming who the call is with.
  test "a voice call in progress is named first: the move ends it before it starts", ctx do
    for {endpoint, who} <- [
          {"phone:0d7f6a52", "from your phone"},
          {"desktop", "on this computer"},
          {"accessory:k151-01", "from an accessory"}
        ] do
      holder = %{endpoint: endpoint, engine: "openai_live", started_at: @now}
      opts = Keyword.put(opts(ctx), :call_holder, fn -> {:ok, holder} end)

      assert %{items: [first | _rest]} = MoveReadiness.report(ctx.home, ctx.candidate, opts)

      assert first == %{
               id: "call_in_progress",
               status: :warn,
               sentence: "A voice call #{who} is in progress: the move ends it before it starts."
             }
    end

    opts = Keyword.put(opts(ctx), :call_holder, fn -> :none end)
    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts)
    refute item_in(items, "call_in_progress")
  end

  # M91 D7, D13: a home moved to a server carries the StackChan's pairing but
  # starts no accessory link there, so a Mac whose home has it on names it.
  test "on a Mac, StackChan turned on is named among what stops after the move", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), "")

    File.write!(MachineFile.path(ctx.home), """
    [fermix_channels.accessories]
    enabled = true
    """)

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert %{status: :warn, sentence: sentence} = item_in(items, "stays_here")
    assert sentence == "StackChan stops after the move: neither this Mac nor north-box runs it."

    linux = Keyword.put(opts(ctx), :host, "linux-x86_64")
    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, linux)
    assert %{status: :ok} = item_in(items, "stays_here")
  end

  # M97 §4: what runs only on this computer is read from its machine file; a
  # section an earlier engine left in config.toml is read by nothing. iMessage
  # is the home's, and never named: the Mac carries it for its server (§6.4).
  test "StackChan is read from this computer's machine file only, iMessage never named", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_channels.imessage]
    enabled = true

    [fermix_channels.accessories]
    enabled = true
    """)

    File.write!(MachineFile.path(ctx.home), "")

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert %{status: :ok, sentence: "Voice calls and meetings are not turned on."} =
             item_in(items, "stays_here")

    assert MoveReadiness.stays_here(ctx.home, true, unreadable_files: nil) == {:ok, []}
  end

  test "on a Linux computer, voice calls on are named, and iMessage never is", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_core.realtime]
    enabled = true
    """)

    linux = Keyword.put(opts(ctx), :host, "linux-x86_64")
    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, linux)

    assert %{status: :warn, sentence: sentence} = item_in(items, "stays_here")

    # M87 §07: the computer's own voice stops; the phone's calls follow the home.
    assert sentence ==
             "This computer's voice calls stop after the move; calls from your phone " <>
               "carry on at north-box when Talk to Fermix is on there and its key is in " <>
               "north-box's secret store."

    File.write!(Path.join(ctx.home, "config.toml"), "")
    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, linux)

    assert %{status: :ok, sentence: "Voice calls and meetings are not turned on."} =
             item_in(items, "stays_here")
  end

  test "a home over one S3 upload warns where the server keeps snapshots in S3", ctx do
    s3 = %{ctx.candidate | snapshots: %{"s3_bucket" => "invented-bucket", "s3_region" => "eu-1"}}
    big = Keyword.put(opts(ctx), :home_bytes, 6 * 1_073_741_824)

    assert %{items: items} = MoveReadiness.report(ctx.home, s3, big)
    assert %{status: :warn, sentence: sentence} = Enum.find(items, &(&1.id == "s3_size"))
    assert sentence =~ "5 GiB"
  end

  # The apps check their vocabulary against the schema exactly, and the
  # schema's list missed `call_in_progress` once the review began to say it.
  # The ids the review can say are `MoveReadiness.ids/0` (no item is made with
  # any other), and the schema and PROTOCOL.md name exactly those.
  test "the schema and PROTOCOL.md name exactly the ids the review can say" do
    priv = Application.app_dir(:fermix_core, "priv/management")

    %{"$defs" => %{"homeReadinessItem" => %{"description" => description}}} =
      priv |> Path.join("protocol.schema.json") |> File.read!() |> Jason.decode!()

    [_match, listed] = Regex.run(~r/id is (.+?); a client/, description)
    schema_ids = String.split(listed, ~r/, | or /)

    assert Enum.sort(schema_ids) == Enum.sort(MoveReadiness.ids())

    [row] =
      priv
      |> Path.join("PROTOCOL.md")
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "| `home.move.readiness` |"))

    for id <- MoveReadiness.ids(), do: assert(row =~ "`#{id}` (", id)
  end

  # EC2 test 2026-11-08: a dev plugin folder whose links name checkouts outside
  # the home blocked the move. The folder and the setting that names it stay
  # on this computer (`DeviceLocal`), so the review does not block on them and
  # says so in one warning, after the plugins.
  test "dev plugins stay on this computer: one warning, and nothing blocks", ctx do
    :ok =
      SecretWriter.put(:anthropic_api_key, "sk-ant-invented",
        profile: ctx.profile,
        store: :keyring
      )

    dev = Path.join(ctx.home, "dev-plugins")
    File.mkdir_p!(dev)
    File.ln_s!("/etc", Path.join(dev, "tesla"))
    # The dev plugin folder is this computer's own (M97 §4).
    machine = MachineFile.path(ctx.home)

    File.write!(
      machine,
      File.read!(machine) <> ~s(\n[fermix_core.plugins]\ndev_local = "#{dev}"\n)
    )

    for {host, machine} <- [{"macos-aarch64", "Mac"}, {"linux-x86_64", "computer"}] do
      seams = Keyword.put(opts(ctx), :host, host)
      assert %{ready: true, items: items} = MoveReadiness.report(ctx.home, ctx.candidate, seams)

      ids = Enum.map(items, & &1.id)

      assert Enum.take(Enum.drop_while(ids, &(&1 != "plugins")), 3) ==
               ~w(plugins dev_plugins stays_here)

      assert item_in(items, "dev_plugins") == %{
               id: "dev_plugins",
               status: :warn,
               sentence: "Dev plugins stay on this #{machine}: north-box runs none of them."
             }
    end
  end

  # EC2 test 2026-11-08: a home the move cannot carry blocked with "Fermix's
  # log says why". The review names the path and what to do, in the words
  # `fermix home export` uses for the same home (`Archive.collect_sentence/1`).
  describe "a home the move cannot carry" do
    test "a link out of the home blocks, naming it", ctx do
      File.mkdir_p!(Path.join(ctx.home, "workspace"))
      File.ln_s!("/etc", Path.join(ctx.home, "workspace/notes"))

      assert %{ready: false, items: items} =
               MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

      assert item_in(items, "disk") == %{
               id: "disk",
               status: :block,
               sentence:
                 "workspace/notes in the home links to /etc, outside the home, which an " <>
                   "archive cannot carry. Move it out of the home, then try again."
             }
    end

    test "a special file blocks, naming it", ctx do
      File.mkdir_p!(Path.join(ctx.home, "workspace"))
      {_out, 0} = System.cmd("mkfifo", [Path.join(ctx.home, "workspace/pipe")])

      assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

      assert %{status: :block, sentence: sentence} = item_in(items, "disk")

      assert sentence ==
               "workspace/pipe in the home is a special file, which an archive cannot " <>
                 "carry. Move it out of the home, then try again."
    end

    test "a tree nested too deep blocks, naming it", ctx do
      deep = Enum.map_join(1..66, "/", fn _level -> "d" end)
      File.mkdir_p!(Path.join([ctx.home, "workspace", deep]))

      assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

      assert %{status: :block, sentence: sentence} = item_in(items, "disk")
      assert sentence =~ ~r{\Aworkspace(/d)+ in the home is nested too deep for an archive\. }
      assert sentence =~ "Move it out of the home, then try again."
    end
  end

  # Always On setup §9: under `fermix run` at a terminal a move stops Fermix
  # and nothing starts it again.
  test "Fermix run from a terminal warns that the move stops it", ctx do
    terminal = Keyword.put(opts(ctx), :restarts_itself, false)

    assert %{items: items} = report = MoveReadiness.report(ctx.home, ctx.candidate, terminal)
    refute Enum.any?(MoveReadiness.blocks(report), &(&1 =~ "terminal"))

    assert item_in(items, "service") == %{
             id: "service",
             status: :warn,
             sentence:
               "Fermix runs from a terminal here, so it stops when the move starts. Start it " <>
                 "again to finish."
           }

    assert %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
    assert %{status: :ok} = item_in(items, "service")
  end

  # What Move now's confirm is built from before the owner presses it: the
  # items that read the settings alone, as the full review gives them.
  test "the items that read the settings alone are the review's, in its order", ctx do
    report = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    for restarts? <- [true, false] do
      seams = Keyword.put(opts(ctx), :restarts_itself, restarts?)
      items = settings_items(ctx, seams)

      assert Enum.map(items, & &1.id) ==
               ~w(stays_here whatsapp slack coding_agents settings cutover_gap serves_nothing service)

      full = MoveReadiness.report(ctx.home, ctx.candidate, seams).items
      assert items == Enum.filter(full, &(&1.id in Enum.map(items, fn item -> item.id end)))
    end

    assert Enum.take(report.items, -8) == settings_items(ctx, opts(ctx))
  end

  test "the items that read the settings alone say an unreadable file", ctx do
    SafeRm.rm!(Path.join(ctx.home, "config.toml"))
    File.mkdir!(Path.join(ctx.home, "config.toml"))
    seams = opts(ctx) ++ [unreadable_files: nil]

    {items, log} =
      ExUnit.CaptureLog.with_log(fn ->
        settings_items(ctx, seams)
      end)

    assert log =~ "could not be read"

    for id <- ~w(stays_here whatsapp slack coding_agents) do
      assert item_in(items, id) == %{
               id: id,
               status: :warn,
               sentence: "The settings file could not be read; Fermix's log says why."
             }
    end
  end

  test "the report as the wire carries it" do
    report = %{ready: false, items: [%{id: "disk", status: :block, sentence: "No room."}]}

    assert MoveReadiness.view(report) == %{
             "ready" => false,
             "items" => [%{"id" => "disk", "status" => "block", "sentence" => "No room."}]
           }
  end

  # A secret no settings row shows is counted, never named by its id, and a
  # keychain item of no setting Fermix knows is said without its key.
  test "a secret with no settings label is counted, and an unknown item is not named", ctx do
    File.write!(Path.join(ctx.home, "config.toml"), """
    [fermix_core]
    profile = "#{ctx.profile}"

    [fermix_core.providers.anthropic]
    api_key = "@keyring"

    [fermix_core.providers.openai]
    api_key = "@keyring"
    """)

    unlabelled = Keyword.put(opts(ctx), :secret_names, %{"anthropic_api_key" => "Anthropic key"})
    %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, unlabelled)

    assert item_in(items, "keychain_secrets").sentence ==
             "The keychain did not give Fermix your Anthropic key and 1 other secret: unlock " <>
               "it, or set them again or clear them in settings, then check again."

    File.write!(Path.join(ctx.home, "config.toml"), """
    [invented.section]
    token = "@keyring"
    """)

    %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))

    assert item_in(items, "keychain_secrets").sentence ==
             "Fermix cannot tell which setting a keychain item belongs to: set it again in " <>
               "settings, then check again."
  end

  # Always On setup §3.1: Move now's confirm is built at `ready` from the
  # items that need neither the keychain nor a walk of the home, which the
  # summary reads on every `home.status`; they are the review's own, so the
  # full review at the press names them in the same words.
  describe "the items the summary reads" do
    test "are the review's last items, in its order and its words", ctx do
      %{items: items} = MoveReadiness.report(ctx.home, ctx.candidate, opts(ctx))
      settings = MoveReadiness.settings(ctx.home, unreadable_files: nil)
      summary = MoveReadiness.summary_items(settings, true, "north-box", opts(ctx))

      assert Enum.map(summary, & &1.id) ==
               ~w(stays_here whatsapp slack coding_agents settings cutover_gap serves_nothing service)

      assert Enum.take(items, -length(summary)) == summary
    end

    test "read settings that cannot be read as the review does", ctx do
      File.write!(Path.join(ctx.home, "config.toml"), "not = [toml")
      File.chmod!(Path.join(ctx.home, "config.toml"), 0o000)
      on_exit(fn -> File.chmod(Path.join(ctx.home, "config.toml"), 0o600) end)

      assert {:error, sentence} = MoveReadiness.settings(ctx.home, unreadable_files: nil)
      items = MoveReadiness.summary_items({:error, sentence}, false, "north-box", opts(ctx))

      assert %{status: :warn, sentence: ^sentence} = item_in(items, "whatsapp")
      assert %{status: :warn} = item_in(items, "serves_nothing")
    end
  end

  # A release table that pins 0.17.0 and 0.18.0, with `rows` after.
  defp release_table(rows) do
    digests =
      for version <- ["0.17.0", "0.18.0"],
          do: "#{version} #{String.duplicate("c", 64)} fermix_always_on.sh"

    Enum.join(["format 1", "latest 0.18.0"] ++ digests ++ rows, "\n") <> "\n"
  end

  defp opts(ctx),
    do: [
      free_bytes: fn _dir -> {:ok, @plenty} end,
      version: "0.17.0",
      host: "macos-aarch64",
      index_opts: [seed_path: ctx.index],
      restarts_itself: true
    ]

  defp item_in(items, id), do: Enum.find(items, &(&1.id == id))

  # The items Move now's confirm is built from, read as the summary reads them.
  defp settings_items(ctx, seams) do
    settings = MoveReadiness.settings(ctx.home, seams)
    MoveReadiness.summary_items(settings, true, ctx.candidate.name, seams)
  end

  defp catalog_entry(name, version, targets) do
    %{
      "name" => name,
      "latest" => version,
      "versions" => [
        %{
          "version" => version,
          "artifacts" =>
            for target <- targets do
              %{
                "target" => target,
                "url" => "https://example.com/#{name}-#{target}.tar.gz",
                "sha256" => String.duplicate("0", 64),
                "sig_url" => "https://example.com/#{name}-#{target}.sig",
                "cert_url" => "https://example.com/#{name}-#{target}.pem"
              }
            end
        }
      ]
    }
  end

  defp candidate_attrs do
    %{
      name: "north-box",
      os: "linux",
      arch: "aarch64",
      version: "0.17.0",
      node_id: String.duplicate("ab", 32),
      relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
      noise_pk: :binary.copy(<<1>>, 32),
      recipient: :binary.copy(<<2>>, 32),
      snapshots: nil
    }
  end
end
