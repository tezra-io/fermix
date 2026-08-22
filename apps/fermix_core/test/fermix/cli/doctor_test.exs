defmodule Fermix.CLI.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Fermix.CLI.Doctor

  test "without --full, prints a report and exits with a valid status" do
    test_self = self()
    ensure_fermix_on_path()

    output =
      capture_io(fn ->
        send(test_self, {:doctor_status, Doctor.run([])})
      end)

    status =
      receive do
        {:doctor_status, value} -> value
      after
        100 -> 0
      end

    assert status in [0, 1]
    assert output =~ "fermix doctor"
    assert output =~ "setup secrets"
    assert output =~ "ok,"
    assert output =~ "warning(s)"
    assert output =~ "failure(s)"
  end

  test "not-applicable rows render and count as their own class, not as passes" do
    results = [
      %{name: "workspace", status: :ok, detail: "fine"},
      %{name: "binary integrity", status: :not_applicable, detail: "managed by Fermix.app"},
      %{name: "upgrade", status: :not_applicable, detail: "managed by Fermix.app"}
    ]

    output = capture_io(fn -> Doctor.print_report(results) end)

    assert output =~ "[N/A ] binary integrity"
    assert output =~ "[N/A ] upgrade"
    assert output =~ "1 ok, 0 warning(s), 0 failure(s), 2 not applicable"
  end

  test "not-applicable rows do not fail the run, and a failure still does" do
    assert Doctor.exit_for([%{name: "upgrade", status: :not_applicable, detail: "n/a"}]) == 0

    assert Doctor.exit_for([
             %{name: "upgrade", status: :not_applicable, detail: "n/a"},
             %{name: "workspace", status: :fail, detail: "broken"}
           ]) == 1
  end

  test "rejects unknown options with non-zero exit" do
    test_self = self()

    output =
      capture_io(:stderr, fn ->
        send(test_self, {:doctor_status, Doctor.run(["--bogus"])})
      end)

    status =
      receive do
        {:doctor_status, value} -> value
      after
        100 -> 0
      end

    assert status == 1
    assert output =~ "invalid options"
  end

  # `fermix doctor` resolves the installed binary path; under `mix test` there
  # is no Burrito wrapper and a clean runner has no `fermix` on PATH, so the
  # service check would raise. Provide a throwaway executable so the resolver
  # succeeds on any host. No-op when a real `fermix` is already installed.
  defp ensure_fermix_on_path do
    if System.find_executable("fermix"), do: :ok, else: install_fake_fermix()
  end

  defp install_fake_fermix do
    bin_dir =
      Path.join(System.tmp_dir!(), "fermix-doctor-bin-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    fake = Path.join(bin_dir, "fermix")
    File.write!(fake, "#!/bin/sh\nexit 0\n")
    File.chmod!(fake, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", "#{bin_dir}:#{original_path}")
    on_exit(fn -> restore_path_and_cleanup(original_path, bin_dir) end)
    :ok
  end

  defp restore_path_and_cleanup(original_path, bin_dir) do
    if original_path, do: System.put_env("PATH", original_path), else: System.delete_env("PATH")
    FermixTestSupport.SafeRm.rm_rf!(bin_dir)
  end
end
