defmodule Fermix.CLI.VersionBootTest do
  @moduledoc """
  A version query creates no home (EC2 test 2026-11-08: `fermix --version`
  run as root wrote `/root/.fermix/secret_key_base`).

  The write came from `config/runtime.exs`, the boot config-provider chain a
  release evaluates before any application starts, which made the web
  listener's signing key for every verb. Nothing in-process can see that
  chain run as a release runs it, so a subprocess evaluates the file for
  `:prod` with the verb's own argv, then runs the verb, as the Burrito
  binary's boot does. (The 127 MB runtime Burrito's wrapper unpacks into
  `~/.local` happens before any of this runs, and is not Fermix's to stop.)

  Tagged `:subprocess` (`mix test --exclude subprocess` skips it).
  """

  use ExUnit.Case, async: false

  alias FermixTestSupport.SafeRm

  @moduletag :subprocess

  setup do
    root = SafeRm.make_tmp_dir!("version-boot")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{home: Path.join(root, "no-home-yet")}
  end

  for argv <- [["--version"], ["version"]] do
    @argv argv

    test "#{Enum.join(argv, " ")} answers its version and writes no home", %{home: home} do
      {out, status} =
        System.cmd("mix", mix_args(@argv),
          cd: umbrella_root(),
          env: [
            {"MIX_ENV", Atom.to_string(Mix.env())},
            {"FERMIX_HOME", home},
            {"SECRET_KEY_BASE", nil}
          ],
          stderr_to_stdout: true
        )

      assert status == 0, out
      assert out =~ ~r/^fermix \d+\.\d+\.\d+/m
      refute File.exists?(home), "the boot made #{home}: #{inspect(File.ls(home))}"
    end
  end

  defp mix_args(argv) do
    [
      "run",
      "--no-start",
      "--no-compile",
      "-e",
      ~s|Config.Reader.read!("config/runtime.exs", env: :prod); | <>
        ~s|System.halt(Fermix.CLI.main(System.argv()))|,
      "--"
    ] ++ argv
  end

  # `mix test` runs with cwd set to the app directory, but `config/runtime.exs`
  # belongs to the umbrella root.
  defp umbrella_root do
    Mix.Project.build_path() |> Path.dirname() |> Path.dirname()
  end
end
