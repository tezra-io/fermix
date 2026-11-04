defmodule FermixCore.Home.RoleTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixTestSupport.SafeRm

  @marker %{epoch: 3, moved_at: ~U[2026-10-27 09:30:00Z], to: "aws i-0f3b1c"}
  @moved_sentence "This home moved to aws i-0f3b1c on 2026-10-27 at epoch 3; run it in the " <>
                    "device role ([fermix_core.engine] role = \"device\") or restore a " <>
                    "snapshot into an empty home."

  setup do
    root = SafeRm.make_tmp_dir!("home_role")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{root: root}
  end

  defp put_marker(root, :none), do: root
  defp put_marker(root, :marker), do: tap(root, &(:ok = Moved.write(&1, @marker)))
  defp put_marker(root, :invalid), do: tap(root, &File.write!(Moved.path(&1), "{}"))

  describe "resolve/2, the role matrix" do
    for {config, label} <- [{[], "no config"}, {[role: :primary], "role = primary"}] do
      @config config

      test "#{label} and no marker is the primary", %{root: root} do
        assert Role.resolve(put_marker(root, :none), @config) == {:ok, :primary}
      end

      test "#{label} and a marker refuses by name with the marker", %{root: root} do
        assert Role.resolve(put_marker(root, :marker), @config) ==
                 {:error, {:home_moved, @marker}}
      end

      test "#{label} and an invalid marker is its own named error", %{root: root} do
        file = Moved.path(root)

        assert {:error, {:invalid_marker, ^file, _detail}} =
                 Role.resolve(put_marker(root, :invalid), @config)
      end
    end

    for state <- [:none, :marker, :invalid] do
      @state state

      test "role = device is the device whatever the marker (#{state})", %{root: root} do
        assert Role.resolve(put_marker(root, @state), role: :device) == {:ok, :device}
      end
    end

    test "the file's own spellings resolve the same way", %{root: root} do
      assert Role.resolve(root, role: "device") == {:ok, :device}
      assert Role.resolve(root, role: "primary") == {:ok, :primary}
    end
  end

  describe "boot/2, what a boot records" do
    test "a primary records no primary elsewhere", %{root: root} do
      assert Role.boot(root, []) == {:ok, %{role: :primary, primary: nil}}
    end

    test "a device records where the marker says the primary went", %{root: root} do
      assert Role.boot(put_marker(root, :marker), role: :device) ==
               {:ok, %{role: :device, primary: "aws i-0f3b1c"}}
    end

    test "a device with no marker knows no primary", %{root: root} do
      assert Role.boot(root, role: :device) == {:ok, %{role: :device, primary: nil}}
    end

    test "a moved home refuses to boot as the primary", %{root: root} do
      assert Role.boot(put_marker(root, :marker), []) == {:error, {:home_moved, @marker}}
    end
  end

  describe "the boot refusal" do
    test "a moved home names where it went, when and at which epoch" do
      assert Role.error_sentence({:home_moved, @marker}) == @moved_sentence
    end

    test "remember!/2 refuses a moved home with that one sentence", %{root: root} do
      put_marker(root, :marker)

      assert_raise RuntimeError, @moved_sentence, fn -> Role.remember!(root, []) end
    end

    test "an invalid marker refuses the primary role with its path named", %{root: root} do
      put_marker(root, :invalid)
      file = Moved.path(root)

      error = assert_raise RuntimeError, fn -> Role.remember!(root, role: :primary) end
      assert error.message =~ file
      assert error.message =~ ~s([fermix_core.engine] role = "device")
    end

    test "an unreadable marker names the path and what the system said", %{root: root} do
      File.mkdir!(Moved.path(root))
      file = Moved.path(root)

      assert {:error, {:file, ^file, :eisdir}} = Role.resolve(root, [])
      assert Role.error_sentence({:file, file, :eisdir}) =~ file
      assert Role.error_sentence({:file, file, :eisdir}) =~ "illegal operation on a directory"
    end
  end

  describe "admit/1" do
    test "the primary admits every turn and every provider call" do
      assert Role.admit(%{role: :primary, primary: nil}) == :ok
    end

    test "a device refuses by name and says where the primary is" do
      assert Role.admit(%{role: :device, primary: "aws i-0f3b1c"}) ==
               {:error,
                {:device_role,
                 "This engine runs in the device role; the primary is aws i-0f3b1c."}}
    end

    test "a device that knows no primary says elsewhere" do
      assert Role.admit(%{role: :device, primary: nil}) ==
               {:error,
                {:device_role, "This engine runs in the device role; the primary is elsewhere."}}
    end
  end

  # A tree-less CLI verb boots no engine, so it reads the role its home is
  # configured for, through the settings file's own parse, and the marker.
  describe "admit_configured/1" do
    test "a home with no settings file and no marker is the primary", %{root: root} do
      assert Role.admit_configured(root) == :ok
    end

    test "a home configured as a device refuses, naming where the marker says the primary is",
         %{root: root} do
      File.write!(Path.join(root, "config.toml"), ~s([fermix_core.engine]\nrole = "device"\n))
      assert Role.admit_configured(root) == device_refusal("elsewhere")

      put_marker(root, :marker)
      assert Role.admit_configured(root) == device_refusal("aws i-0f3b1c")
    end

    test "a home that moved refuses like a device whatever its role says", %{root: root} do
      put_marker(root, :marker)
      assert Role.admit_configured(root) == device_refusal("aws i-0f3b1c")

      File.write!(Path.join(root, "config.toml"), ~s([fermix_core.engine]\nrole = "primary"\n))
      assert Role.admit_configured(root) == device_refusal("aws i-0f3b1c")
    end

    test "a marker that cannot be read refuses with its own sentence", %{root: root} do
      put_marker(root, :invalid)
      assert {:error, {:invalid_marker, _path, _detail} = reason} = Role.admit_configured(root)
      assert Role.refusal_sentence(reason) =~ "is not one Fermix wrote"
    end

    # Only the engine section is normalised: a bad value elsewhere, which a boot
    # refuses by its own key, does not stop a verb that needs the role.
    test "a bad value in another section still yields the role", %{root: root} do
      File.write!(
        Path.join(root, "config.toml"),
        ~s([fermix_core.cues]\ndoor_port = "not a port"\n\n[fermix_core.meetings]\n) <>
          ~s(bogus_key = 1\n\n[fermix_core.engine]\nrole = "device"\n)
      )

      assert Role.admit_configured(root) == device_refusal("elsewhere")
    end

    test "an engine section that cannot be read is a named refusal with its path",
         %{root: root} do
      file = Path.join(root, "config.toml")
      File.write!(file, ~s([fermix_core.engine]\nrole = "mirror"\n))

      assert {:error, {:config, ^file, detail} = reason} = Role.admit_configured(root)
      assert detail =~ "role must be"
      assert Role.refusal_sentence(reason) =~ "could not read the engine role from #{file}"
    end

    test "a settings file that cannot be read is a named refusal with its path", %{root: root} do
      file = Path.join(root, "config.toml")
      File.mkdir!(file)

      assert Role.admit_configured(root) == {:error, {:config, file, :eisdir}}

      assert Role.refusal_sentence({:config, file, :eisdir}) =~
               "(illegal operation on a directory)"
    end

    test "the refusal's sentence is the one a person is shown" do
      {:error, reason} = device_refusal("aws i-0f3b1c")

      assert Role.refusal_sentence(reason) ==
               "This engine runs in the device role; the primary is aws i-0f3b1c."
    end
  end

  defp device_refusal(primary),
    do:
      {:error, {:device_role, "This engine runs in the device role; the primary is #{primary}."}}

  describe "booted/0 and recorded/0" do
    test "an engine reads back the record its boot made" do
      assert Role.booted() == Role.recorded()
      assert Role.current() in [:primary, :device]
    end

    test "anything but a well-formed record reads as no record, never a crash" do
      for term <- [nil, :garbage, %{role: :tertiary, primary: nil}, %{role: :device}, %{}] do
        assert Role.as_record(term) == nil, inspect(term)
      end

      record = %{role: :device, primary: "aws i-0f3b1c"}
      assert Role.as_record(record) == record
    end
  end

  describe "normalize/1 and to_keyword/1, [fermix_core.engine]" do
    test "an absent section is empty, which is the primary", %{root: root} do
      assert Role.normalize(nil) == []
      assert Role.normalize(%{}) == []
      assert Role.resolve(root, Role.normalize(nil)) == {:ok, :primary}
    end

    test "the file's strings become atoms and to_keyword spells them back" do
      assert Role.normalize(%{"role" => "device"}) == [role: :device]
      assert Role.normalize(%{"role" => "primary"}) == [role: :primary]
      assert Role.to_keyword(role: :device) == [role: "device"]
      assert Role.to_keyword([]) == []
    end

    test "normalize is idempotent over its own output and over to_keyword's" do
      for shape <- [[role: :device], [role: "device"], [role: :primary], []] do
        normalized = Role.normalize(shape)
        assert Role.normalize(normalized) == normalized
        assert normalized |> Role.to_keyword() |> Role.normalize() == normalized
      end
    end

    test "a role that is neither is refused with the key named" do
      error = assert_raise ArgumentError, fn -> Role.normalize(%{"role" => "secondary"}) end
      assert error.message =~ "[fermix_core.engine] role"
      assert error.message =~ ~s("secondary")
    end

    test "an unknown key is refused by name" do
      error = assert_raise ArgumentError, fn -> Role.normalize(%{"roll" => "device"}) end
      assert error.message =~ "[fermix_core.engine]"
      assert error.message =~ "roll"
    end
  end

  describe "children/2 and primary_only/0" do
    test "the primary keeps every child as it was declared" do
      children = [FermixCore.Jobs.Scheduler, {FermixCore.Agents.MainAgent, []}]
      assert Role.children(children, :primary) == children
    end

    test "a device leaves out every primary-only child in each child-spec shape" do
      children = [
        FermixCore.Jobs.RunnerSupervisor,
        {FermixCore.Jobs.Scheduler, []},
        Supervisor.child_spec({FermixCore.Cues.Supervisor, []}, id: :cues),
        FermixCore.Agents.MainAgent,
        {Task.Supervisor, name: :kept}
      ]

      assert Role.children(children, :device) == [
               FermixCore.Agents.MainAgent,
               {Task.Supervisor, name: :kept}
             ]
    end

    test "every primary-only entry names a module and the reason it is left out" do
      for {module, reason} <- Role.primary_only_reasons() do
        assert is_atom(module)
        assert is_binary(reason) and reason != ""
      end

      assert Role.primary_only() == Keyword.keys(Role.primary_only_reasons())
    end

    test "a child in no shape a supervisor accepts is refused, never kept by default" do
      assert_raise ArgumentError, fn -> Role.children(["not a child"], :device) end
    end
  end
end
