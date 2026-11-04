defmodule FermixCore.Home.EpochInitialiseTest do
  # Log assertions at info, so the Logger level is raised for this module alone
  # and it runs on its own (AGENTS.md, "Tests under load").
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Home.Epoch
  alias FermixTestSupport.SafeRm

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    root = SafeRm.make_tmp_dir!("home_epoch_initialise")

    on_exit(fn ->
      Logger.configure(level: previous_level)
      SafeRm.rm_rf!(root)
    end)

    %{root: root}
  end

  test "a home without an epoch gets 1, logged once", %{root: root} do
    log =
      capture_log([level: :info], fn -> assert Epoch.initialise(root) == {:ok, :created, 1} end)

    assert log =~ "primary epoch initialised at 1 for a home without one: " <> Epoch.path(root)
    assert Epoch.read(root) == {:ok, 1}

    quiet =
      capture_log([level: :info], fn -> assert Epoch.initialise(root) == {:ok, :present, 1} end)

    refute quiet =~ "primary epoch initialised"
  end

  test "an existing epoch is kept as it is", %{root: root} do
    :ok = Epoch.write(root, 7)
    assert Epoch.initialise(root) == {:ok, :present, 7}
    assert Epoch.read(root) == {:ok, 7}
  end

  test "an invalid epoch is an error with one sentence naming the file", %{root: root} do
    file = Epoch.path(root)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "two\n")

    assert {:error, {:invalid_epoch, ^file, _excerpt} = reason} = Epoch.initialise(root)
    sentence = Epoch.error_sentence(reason)
    assert sentence =~ file
    assert sentence =~ "not one positive integer"
    assert File.read!(file) == "two\n"
  end
end
