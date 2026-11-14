defmodule FermixChannels.Home.RecorderAfterTakingBackTest do
  # M97 stage 4: a Linux computer that took its home back from the server,
  # another computer still linked to it, holds that computer's desktop row in
  # the home's device list, the fact `Home.ServerPrimary` reads (S3 backups'
  # rule). It runs the Fermix Linux app, so by the facts that define an Always
  # On server (`Home.AlwaysOn.here?/1`) it is none: its recorder records, and
  # its screen's and history's sections stay published.
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.DeviceStore
  alias FermixCore.ComputerHistory
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.ServerPrimary
  alias FermixCore.Management.Settings.Tools
  alias FermixTestSupport.SafeRm

  @primary %{role: :primary, primary: nil}
  @linux_desktop %{install: :linux_package_cli, os: :linux, linux_app: true}

  setup do
    home = SafeRm.make_tmp_dir!("recorder_taking_back")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    :ok = Epoch.write(home, 3)
    {:ok, _device} = DeviceStore.add(desktop_row("studio-mac"), root: home)
    %{home: home}
  end

  test "the linked computer's desktop row makes it no server, and it records", %{home: home} do
    assert ServerPrimary.check(home, macos?: false) == :server

    facts = [home: home, booted: @primary, host_facts: @linux_desktop]
    assert ComputerHistory.recorder?(system: :linux, always_on: facts)

    ids = [always_on: facts] |> Tools.sections() |> Enum.map(& &1.id)
    assert "computer_history" in ids
    assert "computer_use" in ids
  end

  defp desktop_row(name),
    do: %{
      device_id: uuid(),
      name: name,
      model: "macos desktop",
      noise_pk: :crypto.strong_rand_bytes(32),
      created_at: ~U[2031-05-01 10:00:00Z],
      kind: :desktop
    }

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end
end
