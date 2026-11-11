defmodule FermixCore.Computers.ArgumentTest do
  # M97 §6.5: the `computer` argument appears on an owner's turn, where Always On
  # is offered and the home has a computer, on each tool whose capability some
  # computer offers, and lists the names of the computers that offer it.
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.Advertisement
  alias FermixCore.Capabilities.Builtin
  alias FermixCore.Computers.Argument
  alias FermixCore.Computers.Capabilities.Files
  alias FermixCore.Computers.Capabilities.Shell, as: ShellCapability
  alias FermixCore.Computers.Computer
  alias FermixCore.Tools.FileRead
  alias FermixCore.Tools.Shell
  alias FermixCore.Tools.WebFetch

  # A tool that refreshes its own schema each turn and can run on a computer:
  # the argument must survive the refresh.
  defmodule RefreshingTool do
    @moduledoc false
    def name, do: "refreshing_read"
    def description, do: "Reads with a schema it builds each turn."
    def parameters, do: %{type: "object", properties: %{path: %{type: "string"}}}
    def dynamic_parameters(_context), do: %{type: "object", properties: %{at: %{type: "string"}}}
    def computer_capability, do: Files
    def execute(_args, _context), do: {:ok, %{success: true, output: "", error: nil}}
  end

  defp offer(id, state, detail \\ nil),
    do: %{
      id: id,
      state: state,
      sentence: if(state == :on, do: nil, else: "Off there."),
      detail: detail
    }

  defp studio,
    do: %Computer{
      device_id: "a1",
      name: "studio Mac",
      platform: :macos,
      connected: true,
      offers: [offer("files", :on), offer("shell", :on, "standard")]
    }

  defp loft,
    do: %Computer{
      device_id: "b2",
      name: "loft Linux",
      platform: :linux,
      connected: false,
      last_seen: ~U[2026-11-06 14:05:00Z],
      offers: [offer("files", :on), offer("shell", :off)]
    }

  # One past the version window offers nothing, whatever it said.
  defp attic,
    do: %Computer{device_id: "c3", name: "attic Mac", standing: :settings_only, offers: []}

  defp owner(computers),
    do: %{source_trust: :operator, always_on: true, computers: computers}

  defp computer_property(capability),
    do: capability.parameters |> Map.get(:properties, %{}) |> Map.get(:computer)

  test "a tool a computer can run carries its capability; one no computer serves does not" do
    assert Builtin.from_tool_module(FileRead).metadata.computer == Files
    assert Builtin.from_tool_module(Shell).metadata.computer == ShellCapability
    refute Map.has_key?(Builtin.from_tool_module(WebFetch).metadata, :computer)
  end

  test "the argument lists the computers that offer the tool's capability, an away one too" do
    computers = [studio(), loft(), attic()]
    read = Argument.add(Builtin.from_tool_module(FileRead), computers)
    shell = Argument.add(Builtin.from_tool_module(Shell), computers)

    assert %{type: "string", enum: ["studio Mac", "loft Linux"], description: words} =
             computer_property(read)

    assert words =~ "## Computers"
    assert computer_property(shell).enum == ["studio Mac"]
    # The tool's own arguments are untouched, and the argument is never required.
    assert Map.has_key?(read.parameters.properties, :path)
    refute "computer" in read.parameters.required
  end

  test "no argument when no computer offers the capability, or the tool has none" do
    only_off = [%{loft() | offers: [offer("shell", :off)]}]

    assert computer_property(Argument.add(Builtin.from_tool_module(Shell), only_off)) == nil
    assert computer_property(Argument.add(Builtin.from_tool_module(FileRead), [])) == nil
    assert computer_property(Argument.add(Builtin.from_tool_module(WebFetch), [studio()])) == nil
  end

  test "only an owner's turn where Always On is offered sees the home's computers" do
    assert Argument.computers(owner([studio()])) == [studio()]
    assert Argument.computers(%{owner([studio()]) | source_trust: :guest}) == []
    assert Argument.computers(%{owner([studio()]) | always_on: false}) == []
    assert Argument.computers(Map.delete(owner([studio()]), :source_trust)) == []
  end

  # The rule is `Computers.visible?/1`'s, decided before the link is asked, so
  # a turn that cannot see computers is advertised with no link implementation
  # loaded at all.
  test "a turn that cannot see computers never asks the link" do
    no_link = FermixCore.Computers.ArgumentTest.NoLinkLoaded
    refute Code.ensure_loaded?(no_link)
    capabilities = [Builtin.from_tool_module(FileRead), Builtin.from_tool_module(Shell)]

    for context <- [
          %{source_trust: :guest, computers_opts: [link: no_link, role: :primary]},
          %{source_trust: :operator, computers_opts: [link: no_link, role: :device]},
          %{source_trust: :operator, always_on: false, computers_opts: [link: no_link]},
          %{computers_opts: [link: no_link, role: :primary]}
        ] do
      assert Argument.computers(context) == []
      prepared = Advertisement.prepare(capabilities, context)
      assert Enum.all?(prepared, &(computer_property(&1) == nil))
    end
  end

  describe "the advertised surface" do
    test "an owner's turn with computers gains the argument; a guest's never does" do
      capabilities = [Builtin.from_tool_module(FileRead), Builtin.from_tool_module(WebFetch)]

      [read, fetch] = Advertisement.prepare(capabilities, owner([studio(), loft()]))
      assert computer_property(read).enum == ["studio Mac", "loft Linux"]
      assert computer_property(fetch) == nil

      guest = %{owner([studio(), loft()]) | source_trust: :guest}

      assert Enum.all?(
               Advertisement.prepare(capabilities, guest),
               &(computer_property(&1) == nil)
             )

      none = owner([])
      assert Enum.all?(Advertisement.prepare(capabilities, none), &(computer_property(&1) == nil))
    end

    test "a tool's own schema refresh never drops the argument" do
      capability = Builtin.from_tool_module(RefreshingTool)

      [refreshed] = Advertisement.prepare([capability], owner([studio()]))

      assert Map.has_key?(refreshed.parameters.properties, :at)
      assert computer_property(refreshed).enum == ["studio Mac"]
    end
  end
end
