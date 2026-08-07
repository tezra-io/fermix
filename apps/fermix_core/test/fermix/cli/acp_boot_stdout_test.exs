defmodule Fermix.CLI.AcpBootStdoutTest do
  @moduledoc """
  `fermix acp` must put nothing but ACP protocol bytes on stdout — starting at
  the process's **first** byte, not at the first byte `Fermix.CLI.AcpCommand`
  itself writes. One stray byte desynchronizes the client's JSON-RPC framing.

  This is a subprocess test, and it has to be. The bytes it guards against are
  emitted from `config/runtime.exs`, the boot config-provider chain, which runs
  before any application starts — before ExUnit could exist in that VM, and
  before `AcpCommand.run/2` (whose own redirect is the later, in-process half of
  the same guarantee). Nothing in-process can observe them, so the honest test
  spawns the real thing and reads its two streams apart.

  Tagged `:subprocess` (`mix test --exclude subprocess` skips it); the child
  boots in well under a second because it reuses the build `mix test` just
  compiled.
  """

  use ExUnit.Case, async: false

  alias FermixTestSupport.SafeRm

  @moduletag :subprocess

  setup do
    root = SafeRm.make_tmp_dir!("acp-boot-stdout")
    home = Path.join(root, "home")
    File.mkdir_p!(home)

    # A plaintext secret makes `ConfigStore.bootstrap_runtime_config/1` log
    # exactly one warning while hydrating config — the same `SecretStore` call
    # site that warns about an unresolvable `@keyring` sentinel, minus the OS
    # keychain. The fixture therefore cannot depend on, or touch, host state.
    File.write!(Path.join(home, "config.toml"), """
    [fermix_core.tools.web_search]
    tavily_api_key = "fermix-acp-boot-stdout-fixture"
    """)

    on_exit(fn -> SafeRm.rm_rf!(root) end)

    {:ok, root: root, home: home}
  end

  describe "boot-time stdout purity" do
    test "config hydration logs on stderr and leaves stdout empty", ctx do
      {stdout, stderr, status} = run_acp(ctx)

      # The guarantee, asserted first so a regression reports the leaked bytes
      # themselves rather than a downstream symptom.
      assert stdout == ""

      # …and the three that stop an empty stdout from proving nothing: the boot
      # chain really did log, and the verb really did run and refuse.
      assert stderr =~ "contains plaintext TAVILY_API_KEY"
      assert stderr =~ "Fermix daemon not running"
      assert status == 1
    end
  end

  # --- the subprocess -------------------------------------------------------

  # `System.cmd/3` can only merge the child's streams or let stderr through to
  # the parent's own, and this test is precisely about telling them apart — so
  # the shell redirects stderr to a file and stdout comes back as the result.
  defp run_acp(ctx) do
    err_path = Path.join(ctx.root, "stderr.txt")
    script = ~s(err_file=$1; shift; exec "$@" 2> "$err_file")

    {stdout, status} =
      System.cmd(
        "sh",
        ["-c", script, "fermix-acp-boot-stdout", err_path, "mix" | mix_args()],
        cd: umbrella_root(),
        env: [{"MIX_ENV", Atom.to_string(Mix.env())}, {"FERMIX_HOME", ctx.home}],
        stderr_to_stdout: false
      )

    {stdout, File.read!(err_path), status}
  end

  # The child dispatches through `Fermix.CLI.main/1` on the same argv the
  # release entry point passes, so one argv drives both the boot-time logger
  # move and the verb that depends on it. `--no-compile` keeps it on the build
  # `mix test` is already using (CI compiles only that MIX_ENV), and
  # `--no-start` keeps a second supervision tree away from the real daemon's
  # SQLite writer.
  defp mix_args do
    [
      "run",
      "--no-start",
      "--no-compile",
      "-e",
      "System.halt(Fermix.CLI.main(System.argv()))",
      "--",
      "acp"
    ]
  end

  # `mix test` runs with cwd set to the app directory, but `config/runtime.exs`
  # — the file under test — belongs to the umbrella root. Mix's own build path
  # (`<root>/_build/<env>`) is the reliable way back to it.
  defp umbrella_root do
    Mix.Project.build_path() |> Path.dirname() |> Path.dirname()
  end
end
