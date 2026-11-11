defmodule FermixCore.Setup.MachineFileTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Management.Placement
  alias FermixCore.Setup.MachineFile

  # A home an earlier engine wrote: the home's settings and this computer's
  # own in one file, comments included.
  @old_config """
  [fermix_core]
  profile = "general"

  [sandbox]
  mode = "strict" # this computer's own
  allowed_roots = ["/Users/invented/Projects"]

  [sandbox.env]
  allow = ["INVENTED_TOKEN"]

  [fermix_core.computer_use]
  enabled = true

  [fermix_core.plugins]
  enabled = ["invented-notes"]
  dev_local = "/Users/invented/dev-plugins"

  [fermix_core.computer_history]
  enabled = true
  apps = ["Safari"]

  [fermix_channels.telegram]
  enabled = true

  [fermix_channels.imessage]
  enabled = true

  [fermix_channels.accessories]
  enabled = true
  """

  @removed ~w(sandbox fermix_core.computer_use fermix_channels.accessories
              fermix_core.plugins.dev_local fermix_core.computer_history.enabled
              fermix_core.computer_history.apps)

  test "the machine sections are exactly the ones only this machine configures" do
    assert Enum.sort(Map.keys(MachineFile.sections())) == Enum.sort(Placement.device_sections())
  end

  describe "strip/1 and extract/1" do
    test "split one old file into the home's settings and this computer's, every line kept" do
      {home, removed} = MachineFile.strip(@old_config)

      assert removed == @removed
      assert ConfigText.value(home, "fermix_core", "profile") == {:ok, ~s("general")}

      assert ConfigText.value(home, "fermix_core.plugins", "enabled") ==
               {:ok, ~s(["invented-notes"])}

      assert ConfigText.value(home, "fermix_channels.telegram", "enabled") == {:ok, "true"}
      # The home uses iMessage, with its owner and guests (M97 §4).
      assert ConfigText.value(home, "fermix_channels.imessage", "enabled") == {:ok, "true"}
      refute home =~ "sandbox"
      refute home =~ "computer_use"
      refute home =~ "apps = "
      refute home =~ "accessories"
      refute home =~ "dev_local"

      machine = MachineFile.extract(@old_config)

      assert String.starts_with?(machine, MachineFile.header())
      assert machine =~ ~s(mode = "strict" # this computer's own)
      assert ConfigText.value(machine, "sandbox.env", "allow") == {:ok, ~s(["INVENTED_TOKEN"])}
      assert ConfigText.value(machine, "fermix_core.computer_use", "enabled") == {:ok, "true"}

      assert ConfigText.value(machine, "fermix_core.computer_history", "apps") ==
               {:ok, ~s(["Safari"])}

      refute machine =~ "imessage"
      assert ConfigText.value(machine, "fermix_channels.accessories", "enabled") == {:ok, "true"}

      assert ConfigText.value(machine, "fermix_core.plugins", "dev_local") ==
               {:ok, ~s("/Users/invented/dev-plugins")}

      refute machine =~ "invented-notes"
      refute machine =~ "telegram"
      assert machine |> MachineFile.strip() |> elem(1) == @removed
    end

    test "a file with no machine settings is left as it is and gives no machine file" do
      text = ~s([fermix_core.agent]\nname = "Orchard"\n)
      assert MachineFile.strip(text) == {text, []}
      assert MachineFile.extract(text) == ""
    end

    # M97 §4: computer history splits by key. The home's route and grants stay
    # in config.toml; a summarizer that says "local" is this machine's too, so
    # it is copied and never removed.
    test "computer history splits by key, a local summarizer copied to both" do
      text = """
      [fermix_core.computer_history]
      enabled = true
      apps = ["com.example.Notes"]
      summarizer = "local"
      remote_summaries = ["anthropic"]
      """

      {home, removed} = MachineFile.strip(text)

      assert removed ==
               ~w(fermix_core.computer_history.enabled fermix_core.computer_history.apps)

      assert ConfigText.value(home, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("local")}

      assert ConfigText.value(home, "fermix_core.computer_history", "remote_summaries") ==
               {:ok, ~s(["anthropic"])}

      refute home =~ "enabled"

      machine = MachineFile.extract(text)

      # One table, never a header per key.
      assert length(String.split(machine, "[fermix_core.computer_history]")) == 2
      assert ConfigText.value(machine, "fermix_core.computer_history", "enabled") == {:ok, "true"}

      assert ConfigText.value(machine, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("local")}

      refute machine =~ "remote_summaries"
      assert MachineFile.copied(text) == ["fermix_core.computer_history.summarizer"]
    end

    test "a summarizer that is not local is the home's alone" do
      text = ~s([fermix_core.computer_history]\nenabled = true\nsummarizer = "anthropic"\n)

      assert ConfigText.value(
               MachineFile.extract(text),
               "fermix_core.computer_history",
               "summarizer"
             ) ==
               :absent

      assert MachineFile.copied(text) == []
      {home, _removed} = MachineFile.strip(text)

      assert ConfigText.value(home, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("anthropic")}
    end
  end

  describe "join/2 and drop/1 over decoded documents" do
    test "every machine setting comes from the machine file and nothing else does" do
      config = %{
        "sandbox" => %{"mode" => "open"},
        "fermix_core" => %{
          "agent" => %{"name" => "Orchard"},
          "plugins" => %{"enabled" => ["notes"], "dev_local" => "/from/config"},
          "computer_use" => %{"enabled" => true}
        }
      }

      machine = %{
        "sandbox" => %{"mode" => "strict"},
        "fermix_core" => %{
          "agent" => %{"name" => "Machine"},
          "plugins" => %{"dev_local" => "/from/machine", "enabled" => ["machine"]}
        }
      }

      assert MachineFile.join(config, machine) == %{
               "sandbox" => %{"mode" => "strict"},
               "fermix_core" => %{
                 "agent" => %{"name" => "Orchard"},
                 "plugins" => %{"enabled" => ["notes"], "dev_local" => "/from/machine"}
               }
             }
    end

    test "drop/1 leaves the home's own settings" do
      assert MachineFile.drop(%{
               "sandbox" => %{"mode" => "open"},
               "fermix_channels" => %{
                 "accessories" => %{"enabled" => true},
                 "imessage" => %{"enabled" => true},
                 "slack" => %{}
               }
             }) == %{"fermix_channels" => %{"imessage" => %{"enabled" => true}, "slack" => %{}}}
    end

    test "the iMessage section is the home's: a machine file's copy is not read" do
      config = %{"fermix_channels" => %{"imessage" => %{"owner_user_id" => "+15550104477"}}}
      machine = %{"fermix_channels" => %{"imessage" => %{"owner_user_id" => "+15550109999"}}}
      assert MachineFile.join(config, machine) == config
    end
  end

  # Stage 0 of M97 wrote [fermix_channels.imessage] into machine.toml; the
  # owner and guests are the home's, so a server must know them (§4).
  describe "homeward/2" do
    @stage0_machine """
    # This computer's own settings
    [sandbox]
    mode = "standard"

    [fermix_channels.imessage]
    enabled = true
    owner_user_id = "+15550104477" # the owner's phone
    allowed_sender_ids = ["guest@example.org"]

    [fermix_core.computer]
    imessage = true
    """

    test "the section goes back to config.toml first, then leaves the machine file" do
      config = ~s([fermix_core.agent]\nname = "Orchard"\n)
      plan = MachineFile.homeward(config, @stage0_machine)

      assert plan.moved == ["fermix_channels.imessage"]
      assert ConfigText.value(plan.config, "fermix_core.agent", "name") == {:ok, ~s("Orchard")}

      assert ConfigText.value(plan.config, "fermix_channels.imessage", "owner_user_id") ==
               {:ok, ~s("+15550104477")}

      assert plan.config =~ "# the owner's phone"
      refute plan.machine =~ "[fermix_channels.imessage]"
      assert ConfigText.value(plan.machine, "sandbox", "mode") == {:ok, ~s("standard")}
      # This Mac carries Messages: the switch stays on the machine.
      assert ConfigText.value(plan.machine, "fermix_core.computer", "imessage") == {:ok, "true"}

      assert MachineFile.homeward_notice(plan.moved) =~
               "moved from machine.toml back to config.toml: fermix_channels.imessage."
    end

    # A boot stopped between the two writes finds the section in both: the
    # machine file's copy replaces config.toml's, and the machine file loses it.
    test "an interrupted move finishes and changes nothing in config.toml" do
      first = MachineFile.homeward("", @stage0_machine)
      again = MachineFile.homeward(first.config, @stage0_machine)

      assert again.config == first.config
      assert again.machine == first.machine

      assert MachineFile.homeward(again.config, again.machine) == %{
               config: nil,
               machine: nil,
               moved: []
             }
    end

    test "a machine file without the section, or none, changes nothing" do
      assert MachineFile.homeward("", :absent) == %{config: nil, machine: nil, moved: []}

      assert MachineFile.homeward("", ~s([sandbox]\nmode = "open"\n)) ==
               %{config: nil, machine: nil, moved: []}
    end

    # Stage 0 kept the whole [fermix_core.computer_history] table here. The
    # home's route and grants go back to config.toml; whether this machine
    # records, which apps, and a local summarizer stay.
    @stage0_history """
    [fermix_core.computer_history]
    enabled = true
    apps = ["com.example.Notes"]
    summarizer = "anthropic"
    remote_summaries = ["anthropic"]
    """

    test "the home's history keys go back to config.toml, this machine's stay" do
      plan = MachineFile.homeward(~s([fermix_core.agent]\nname = "Orchard"\n), @stage0_history)

      assert plan.moved ==
               ~w(fermix_core.computer_history.remote_summaries fermix_core.computer_history.summarizer)

      assert ConfigText.value(plan.config, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("anthropic")}

      assert ConfigText.value(plan.config, "fermix_core.computer_history", "remote_summaries") ==
               {:ok, ~s(["anthropic"])}

      refute plan.config =~ "com.example.Notes"

      assert ConfigText.value(plan.machine, "fermix_core.computer_history", "enabled") ==
               {:ok, "true"}

      refute plan.machine =~ "summarizer"
      refute plan.machine =~ "remote_summaries"
    end

    # A Mac that is its own home and chose local: the machine keeps its choice,
    # and config.toml takes it as the home's route where it names none, so the
    # roll-up stays on the Mac and a later move carries the choice.
    test "a local summarizer stays here, and config.toml takes it only where it names none" do
      machine = String.replace(@stage0_history, ~s("anthropic"\n), ~s("local"\n), global: false)
      plan = MachineFile.homeward("", machine)

      assert ConfigText.value(plan.config, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("local")}

      assert ConfigText.value(plan.machine, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("local")}

      # The owner's own route in config.toml is never overwritten from here.
      owned = ~s([fermix_core.computer_history]\nsummarizer = "default"\n)
      again = MachineFile.homeward(owned, plan.machine)
      assert again == %{config: nil, machine: nil, moved: []}
    end

    test "a boot stopped between the writes finishes and changes nothing more" do
      first = MachineFile.homeward("", @stage0_history)
      # Stopped after config.toml was written: the machine file is as it was.
      again = MachineFile.homeward(first.config, @stage0_history)

      assert again.config == first.config
      assert again.machine == first.machine

      assert MachineFile.homeward(again.config, again.machine) == %{
               config: nil,
               machine: nil,
               moved: []
             }
    end
  end

  # A machine setting written into config.toml by hand after the boot moved
  # them, as a reload finds it.
  describe "misplaced_notice/1" do
    test "names what config.toml holds of this computer's, where it belongs, and its end" do
      sentence = MachineFile.misplaced_notice(["sandbox", "fermix_core.plugins.dev_local"])

      assert sentence =~
               "config.toml holds this computer's own settings, which Fermix reads only from " <>
                 "machine.toml, so they are ignored: sandbox, fermix_core.plugins.dev_local."

      assert sentence =~ "Move them to machine.toml"
      assert sentence =~ "the next settings save or start removes them from config.toml"
    end
  end

  describe "migration/3" do
    test "a home with neither file is left as it is" do
      assert MachineFile.migration("", :absent, false) ==
               %{machine: nil, config: nil, removed: [], copied: [], server_default?: false}

      assert MachineFile.notice(MachineFile.migration("", :absent, false)) == nil
    end

    test "a computer's own settings move: the machine file first, then config.toml without them" do
      plan = MachineFile.migration(@old_config, :absent, false)

      assert plan.machine == MachineFile.extract(@old_config)
      assert plan.config == elem(MachineFile.strip(@old_config), 0)
      assert plan.removed == @removed
      refute plan.server_default?
      assert {:info, sentence} = MachineFile.notice(plan)
      assert sentence =~ "moved to machine.toml"
    end

    # A boot stopped between the two writes: the machine file wins, since it
    # was written first, and the removal is finished.
    test "with both files, the machine file is kept and config.toml loses its copy" do
      machine = ~s([sandbox]\nmode = "standard"\n)
      plan = MachineFile.migration(@old_config, machine, false)

      assert plan.machine == nil
      assert plan.config == elem(MachineFile.strip(@old_config), 0)
      assert {:warning, sentence} = MachineFile.notice(plan)
      # True of a section added to config.toml by hand too, which the machine
      # file need not hold.
      assert sentence =~ "which Fermix reads only from machine.toml, so they were removed"
      assert sentence =~ ": sandbox, fermix_core.computer_use"
    end

    test "a migrated home changes nothing" do
      {home, _removed} = MachineFile.strip(@old_config)
      plan = MachineFile.migration(home, MachineFile.extract(@old_config), false)

      assert plan == %{machine: nil, config: nil, removed: [], copied: [], server_default?: false}
      assert MachineFile.notice(plan) == nil
    end

    test "a fresh server's machine file starts from the server's default" do
      plan = MachineFile.migration(~s([fermix_core.engine]\nrole = "primary"\n), :absent, true)

      assert plan.machine == MachineFile.server_default()
      assert ConfigText.value(plan.machine, "sandbox", "mode") == {:ok, ~s("open")}
      assert plan.config == nil
      assert plan.server_default?

      assert MachineFile.notice(plan) ==
               {:info, "This server uses its own sandbox setting: open."}
    end

    # M75's servers moved before this change and hold the Mac's sections.
    test "a server that moved leaves out the settings it inherited and takes its own default" do
      plan = MachineFile.migration(@old_config, :absent, true)

      assert plan.machine == MachineFile.server_default()
      refute plan.machine =~ "strict"
      assert plan.config == elem(MachineFile.strip(@old_config), 0)
      assert plan.removed == @removed

      assert {:warning, sentence} = MachineFile.notice(plan)
      assert sentence =~ "This server now uses its own sandbox setting: open."
      assert sentence =~ "left out: sandbox, fermix_core.computer_use"
    end

    test "a server whose machine file exists keeps it" do
      plan = MachineFile.migration("", ~s([sandbox]\nmode = "strict"\n), true)

      assert plan == %{
               machine: nil,
               config: nil,
               removed: [],
               copied: [],
               server_default?: false
             }
    end

    # A home a released engine wrote, whose owner chose local: the Mac keeps
    # its choice in machine.toml, and the home's route stays local.
    @released_history """
    [fermix_core.agent]
    name = "Orchard"

    [fermix_core.computer_history]
    enabled = true
    apps = ["com.example.Notes"]
    summarizer = "local"
    remote_summaries = ["anthropic"]
    """

    test "a Mac's history: its keys move, a local summarizer is copied, the home's stay" do
      plan = MachineFile.migration(@released_history, :absent, false)

      assert ConfigText.value(plan.machine, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("local")}

      assert ConfigText.value(plan.machine, "fermix_core.computer_history", "apps") ==
               {:ok, ~s(["com.example.Notes"])}

      assert ConfigText.value(plan.config, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("local")}

      assert ConfigText.value(plan.config, "fermix_core.computer_history", "remote_summaries") ==
               {:ok, ~s(["anthropic"])}

      refute plan.config =~ "com.example.Notes"
      assert plan.copied == ["fermix_core.computer_history.summarizer"]
      assert {:info, sentence} = MachineFile.notice(plan)

      assert sentence =~
               "fermix_core.computer_history.apps, fermix_core.computer_history.summarizer."
    end

    # A server never takes a computer's machine keys, and keeps the home's.
    test "a server leaves out the history keys of the computer, and keeps the home's" do
      plan = MachineFile.migration(@released_history, :absent, true)

      assert plan.machine == MachineFile.server_default()
      assert plan.copied == []

      assert plan.removed ==
               ~w(fermix_core.computer_history.enabled fermix_core.computer_history.apps)

      assert ConfigText.value(plan.config, "fermix_core.computer_history", "summarizer") ==
               {:ok, ~s("local")}

      assert ConfigText.value(plan.config, "fermix_core.computer_history", "remote_summaries") ==
               {:ok, ~s(["anthropic"])}

      refute plan.config =~ "com.example.Notes"
    end

    # Stopped after the machine file was written: config.toml still holds the
    # Mac's keys, and the machine file wins.
    test "a boot stopped between the two writes finishes, losing nothing" do
      first = MachineFile.migration(@released_history, :absent, false)
      again = MachineFile.migration(@released_history, first.machine, false)

      assert again.machine == nil
      assert again.config == first.config
      assert again.copied == []
      assert MachineFile.migration(again.config, first.machine, false).config == nil
    end
  end
end
