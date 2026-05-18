defmodule Fermix.CLI.Upgrade.CosignTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Upgrade.Cosign

  setup do
    tmp = Path.join(System.tmp_dir!(), "fermix_cosign_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    blob = Path.join(tmp, "blob")
    sig = Path.join(tmp, "blob.sig")
    cert = Path.join(tmp, "blob.pem")
    File.write!(blob, "release-bytes")
    File.write!(sig, "stub-sig")
    File.write!(cert, "stub-cert")

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(tmp) end)

    %{tmp: tmp, blob: blob, sig: sig, cert: cert}
  end

  defp stub_cosign(%{tmp: tmp}, script) do
    path = Path.join(tmp, "cosign.sh")
    File.write!(path, script)
    File.chmod!(path, 0o755)
    path
  end

  test "requires a manifest version to build the identity regex", ctx do
    cosign = stub_cosign(ctx, "#!/bin/sh\nexit 0\n")

    assert {:error, :missing_version} =
             Cosign.verify(ctx.blob, ctx.sig, ctx.cert, cosign_path: cosign)
  end

  test "passes a version-bound identity regex to cosign", ctx do
    log = Path.join(ctx.tmp, "args.log")

    cosign =
      stub_cosign(ctx, """
      #!/bin/sh
      printf %s "$@" > #{log}
      exit 0
      """)

    assert :ok = Cosign.verify(ctx.blob, ctx.sig, ctx.cert, cosign_path: cosign, version: "1.2.3")

    args = File.read!(log)
    assert args =~ "--certificate-identity-regexp"

    assert args =~
             "^https://github.com/tezra-io/fermix/.github/workflows/release.yml@refs/tags/v1\\.2\\.3$"

    refute args =~ "[\\d.]+"
  end

  test "honours an explicit identity_regex override (for tests/internal callers)", ctx do
    log = Path.join(ctx.tmp, "args.log")

    cosign =
      stub_cosign(ctx, """
      #!/bin/sh
      printf %s "$@" > #{log}
      exit 0
      """)

    assert :ok =
             Cosign.verify(ctx.blob, ctx.sig, ctx.cert,
               cosign_path: cosign,
               identity_regex: "^https://github\\.com/example/repo/.+$"
             )

    assert File.read!(log) =~ "^https://github\\.com/example/repo/.+$"
  end

  test "kills cosign and returns :cosign_timeout when it hangs", ctx do
    cosign =
      stub_cosign(ctx, """
      #!/bin/sh
      sleep 30
      """)

    assert {:error, {:cosign_timeout, 50}} =
             Cosign.verify(ctx.blob, ctx.sig, ctx.cert,
               cosign_path: cosign,
               version: "1.0.0",
               timeout_ms: 50
             )
  end

  test "surfaces cosign non-zero exit", ctx do
    cosign =
      stub_cosign(ctx, """
      #!/bin/sh
      echo bogus 1>&2
      exit 17
      """)

    assert {:error, {:cosign_failed, 17, out}} =
             Cosign.verify(ctx.blob, ctx.sig, ctx.cert,
               cosign_path: cosign,
               version: "1.0.0"
             )

    assert out =~ "bogus"
  end
end
