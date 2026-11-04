defmodule Fermix.CLI.HomeMovedCommandTest do
  # Sync: refusals and usage errors print on `:standard_error`, one globally
  # registered device that concurrent captures would share.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.HomeMovedCommand
  alias Fermix.CLI.MachineOutput
  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Moved
  alias FermixTestSupport.SafeRm

  @now ~U[2026-10-27 09:30:00Z]
  @not_running {:error, :not_running}

  setup do
    home = SafeRm.make_tmp_dir!("home_moved_command")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  # The verb with the probe answering "not running" unless a test says
  # otherwise, and the clock fixed.
  defp run(argv, deps) do
    deps = Keyword.merge([hello: fn -> @not_running end, now: fn -> @now end], deps)
    capture_and_run(fn -> HomeMovedCommand.run(argv, deps) end)
  end

  defp envelope(out), do: Jason.decode!(out)

  test "marks the home moved at its epoch and prints the marker in the envelope", %{home: home} do
    :ok = Epoch.write(home, 4)

    {status, out, err} = run(["--to", "aws i-0f3b1c", "--json"], home: home)

    assert {status, err} == {0, ""}

    assert envelope(out) == %{
             "schema_version" => 1,
             "ok" => true,
             "result" => %{
               "epoch" => 4,
               "moved_at" => "2026-10-27T09:30:00Z",
               "to" => "aws i-0f3b1c"
             }
           }

    assert Moved.read(home) == {:ok, %{epoch: 4, moved_at: @now, to: "aws i-0f3b1c"}}
    assert Epoch.read(home) == {:ok, 4}
  end

  test "human mode says what was recorded and what the home does now", %{home: home} do
    :ok = Epoch.write(home, 4)

    {status, out, err} = run(["--to", "aws i-0f3b1c"], home: home)

    assert {status, err} == {0, ""}
    assert out =~ "Marked #{home} moved to aws i-0f3b1c at epoch 4 (2026-10-27T09:30:00Z)."
    assert out =~ ~s([fermix_core.engine] role = "device")
  end

  test "a home with no primary epoch is refused by name and nothing is written", %{home: home} do
    {status, out, _err} = run(["--to", "aws i-0f3b1c", "--json"], home: home)

    assert status == 1
    assert %{"ok" => false, "error" => %{"code" => "epoch_absent"}} = envelope(out)
    assert Moved.read(home) == :absent
  end

  test "a running engine is refused by name and nothing is written", %{home: home} do
    :ok = Epoch.write(home, 4)

    {status, out, _err} =
      run(["--to", "aws i-0f3b1c", "--json"], home: home, hello: fn -> {:ok, %{}} end)

    assert status == 1
    assert %{"ok" => false, "error" => %{"code" => "daemon_running"}} = envelope(out)
    assert Moved.read(home) == :absent
  end

  test "a probe that cannot tell refuses rather than guessing the engine is stopped",
       %{home: home} do
    :ok = Epoch.write(home, 4)

    {status, out, _err} =
      run(["--to", "aws i-0f3b1c", "--json"], home: home, hello: fn -> {:error, :timeout} end)

    assert status == 1

    assert %{"ok" => false, "error" => %{"code" => "mark_moved_failed", "sentence" => sentence}} =
             envelope(out)

    assert sentence ==
             "Fermix could not mark this home moved. It said: could not tell whether Fermix " <>
               "is running (timeout)"

    assert Moved.read(home) == :absent
  end

  test "a home that already moved is refused by name and its first marker stands",
       %{home: home} do
    :ok = Epoch.write(home, 4)
    first = %{epoch: 3, moved_at: ~U[2026-10-20 08:00:00Z], to: "hetzner cx22"}
    :ok = Moved.write(home, first)

    {status, out, _err} = run(["--to", "aws i-0f3b1c", "--json"], home: home)

    assert status == 1

    assert envelope(out)["error"] == %{
             "code" => "already_moved",
             "sentence" =>
               "This home already moved to hetzner cx22 on 2026-10-20 at epoch 3, and the " <>
                 "first move stands."
           }

    assert Moved.read(home) == {:ok, first}
  end

  test "a refusal in human mode is its sentence on stderr", %{home: home} do
    {status, out, err} = run(["--to", "aws i-0f3b1c"], home: home)

    assert {status, out} == {1, ""}
    assert err == "fermix home mark-moved: #{MachineOutput.sentence(:epoch_absent)}\n"
  end

  test "the real probe finds no engine in a home with no control socket", %{home: home} do
    :ok = Epoch.write(home, 2)

    {status, _out, err} =
      capture_and_run(fn ->
        HomeMovedCommand.run(["--to", "aws i-0f3b1c", "--json"], home: home, now: fn -> @now end)
      end)

    assert {status, err} == {0, ""}
    assert {:ok, %{epoch: 2}} = Moved.read(home)
  end

  describe "usage errors print no envelope" do
    for {label, argv} <- [
          {"--to is missing", ["--json"]},
          {"--to is empty", ["--to", "", "--json"]},
          {"--to holds a line break", ["--to", "a\nb", "--json"]},
          {"an extra argument", ["--to", "x", "extra"]},
          {"an unknown option", ["--to", "x", "--into", "y"]}
        ] do
      @argv argv

      test "when #{label}", %{home: home} do
        :ok = Epoch.write(home, 4)

        {status, out, err} = run(@argv, home: home)

        assert {status, out} == {2, ""}
        assert err =~ "fermix home mark-moved --to TEXT [--json]"
        assert Moved.read(home) == :absent
      end
    end
  end

  # Stdout, stderr and the exit status of one run.
  defp capture_and_run(fun) do
    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(self(), {:status, fun.()}) end)
        send(self(), {:out, out})
      end)

    assert_received {:status, status}
    assert_received {:out, out}
    {status, out, err}
  end
end
