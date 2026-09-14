defmodule Fermix.CLI.MachineBootStdoutTest do
  @moduledoc """
  A `--json` verb must put nothing but its envelope on stdout — starting at the
  process's **first** byte, not at the first byte the command module writes. A
  caller decodes that line without stripping anything first, so a logged warning
  lands inside what it decodes.

  This is a subprocess test for the same reason `AcpBootStdoutTest` is one: the
  bytes it guards against come from `config/runtime.exs`, the boot
  config-provider chain, which runs before any application starts. Nothing
  in-process can observe them, and a headless Linux host with a locked keyring —
  the platform these verbs exist for — is exactly where the hydration logs.

  Tagged `:subprocess` (`mix test --exclude subprocess` skips it).
  """

  use ExUnit.Case, async: false

  alias FermixTestSupport.SafeRm

  @moduletag :subprocess

  setup do
    root = SafeRm.make_tmp_dir!("machine-boot-stdout")
    home = Path.join(root, "home")
    File.mkdir_p!(home)

    # One plaintext secret makes the boot hydration log exactly one warning, the
    # same `SecretStore` call site that warns about an unresolvable `@keyring`
    # sentinel — without depending on, or touching, an OS keychain.
    File.write!(Path.join(home, "config.toml"), """
    [fermix_core.tools.web_search]
    tavily_api_key = "fermix-machine-boot-stdout-fixture"
    """)

    on_exit(fn -> SafeRm.rm_rf!(root) end)

    {:ok, root: root, home: home}
  end

  describe "boot-time stdout purity for machine mode" do
    test "stdout carries one envelope and the hydration warning is on stderr", ctx do
      {stdout, stderr, status} = run_verb(ctx, ["service", "status", "--json"])

      # The guarantee, asserted as the reader experiences it: decode the whole
      # of stdout, not a line picked out of it.
      assert {:ok, envelope} = Jason.decode(String.trim(stdout))
      assert envelope["schema_version"] == 1
      assert envelope["ok"] == false
      assert envelope["error"]["code"] == "foreign_distribution"

      # …and the two that stop a decodable stdout from proving nothing: the boot
      # chain really did log, and it logged somewhere else.
      assert stderr =~ "contains plaintext TAVILY_API_KEY"
      assert status == 1
    end
  end

  # --- the subprocess -------------------------------------------------------

  # `System.cmd/3` can only merge the child's streams or let stderr through to
  # the parent's own, and this test is precisely about telling them apart.
  defp run_verb(ctx, argv) do
    err_path = Path.join(ctx.root, "stderr.txt")
    script = ~s(err_file=$1; shift; exec "$@" 2> "$err_file")

    {stdout, status} =
      System.cmd(
        "sh",
        ["-c", script, "fermix-machine-boot-stdout", err_path, "mix" | mix_args(argv)],
        cd: umbrella_root(),
        env: [{"MIX_ENV", Atom.to_string(Mix.env())}, {"FERMIX_HOME", ctx.home}],
        stderr_to_stdout: false
      )

    {stdout, File.read!(err_path), status}
  end

  defp mix_args(argv) do
    [
      "run",
      "--no-start",
      "--no-compile",
      "-e",
      "System.halt(Fermix.CLI.main(System.argv()))",
      "--"
    ] ++ argv
  end

  # `mix test` runs with cwd set to the app directory, but `config/runtime.exs`
  # — the file under test — belongs to the umbrella root.
  defp umbrella_root do
    Mix.Project.build_path() |> Path.dirname() |> Path.dirname()
  end
end
