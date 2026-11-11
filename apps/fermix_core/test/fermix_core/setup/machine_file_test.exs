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

  @removed ~w(sandbox fermix_core.computer_use fermix_core.computer_history
              fermix_channels.accessories fermix_core.plugins.dev_local)

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
      refute home =~ "computer_history"
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
               %{machine: nil, config: nil, removed: [], server_default?: false}

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

      assert plan == %{machine: nil, config: nil, removed: [], server_default?: false}
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
      assert plan == %{machine: nil, config: nil, removed: [], server_default?: false}
    end
  end
end
