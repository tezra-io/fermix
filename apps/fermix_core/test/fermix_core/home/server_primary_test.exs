defmodule FermixCore.Home.ServerPrimaryTest do
  # D18: S3 backups and their scheduler run only on an Always On server's
  # primary, told by the desktop row a move writes into the home before it
  # captures, and never on macOS. The host and the device list are injected,
  # so the answer is the same on every runner.
  use ExUnit.Case, async: true

  alias FermixCore.Home.ServerPrimary

  @home "/invented/home"
  @mac %{device_id: "11111111-2222-4333-8444-555555555555", name: "orchard-mac"}

  test "a home holding a desktop row, off macOS, is a server's" do
    assert ServerPrimary.check(@home, macos?: false, desktop_rows: rows({:ok, [@mac]})) ==
             :server
  end

  test "a home that never moved holds no desktop row" do
    assert ServerPrimary.check(@home, macos?: false, desktop_rows: rows({:ok, []})) ==
             {:not_server, :no_desktop}
  end

  test "a Mac is never a server, whatever its device list holds" do
    assert ServerPrimary.check(@home, macos?: true, desktop_rows: rows({:ok, [@mac]})) ==
             {:not_server, :macos}
  end

  test "a device list that cannot be read is named, and admits nothing" do
    assert ServerPrimary.check(@home, macos?: false, desktop_rows: rows({:error, :eacces})) ==
             {:not_server, {:device_list, :eacces}}
  end

  test "each answer that is no server has its own sentence" do
    assert ServerPrimary.sentence(:macos) ==
             "Fermix keeps S3 backups only on an Always On server, and this Mac is not one."

    assert ServerPrimary.sentence(:no_desktop) ==
             "Fermix keeps S3 backups only on an Always On server, and this computer is not " <>
               "one: no desktop moved its home here."

    assert ServerPrimary.sentence({:device_list, :eacces}) ==
             "Fermix could not read this home's device list (permission denied), so it " <>
               "cannot tell whether this is an Always On server, and keeps no S3 backup."
  end

  defp rows(answer) do
    fn home ->
      assert home == @home
      answer
    end
  end
end
