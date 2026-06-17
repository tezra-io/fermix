defmodule FermixCore.Plugins.Dist.SeamsTest do
  @moduledoc """
  The Fetcher/Verifier seams: the production Verifier's certificate-identity
  pinning (the security-critical bit — a wrong regex accepts wrong-identity
  certs), and the test stubs' fail-loud / default-deny discipline that lets the
  installer be driven hermetically without a `cosign` binary or the network.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Plugins.Dist.Verifier.Cosign, as: VerifierCosign
  alias FermixTestSupport.DistFetcherStub
  alias FermixTestSupport.DistVerifierStub

  describe "Verifier.Cosign.identity_regex/1" do
    test "pins the fermix-plugins release workflow at the exact <name>/v<version> tag" do
      identity =
        "https://github.com/tezra-io/fermix-plugins/.github/workflows/" <>
          "release-plugin.yml@refs/tags/github/v1.2.0"

      assert {:ok, regex} = VerifierCosign.identity_regex(name: "github", version: "1.2.0")
      # Exact, fully-escaped, anchored — no wildcard dots in the fixed path.
      assert regex == "^" <> Regex.escape(identity) <> "$"

      compiled = Regex.compile!(regex)
      assert Regex.match?(compiled, identity)
      refute Regex.match?(compiled, identity <> "-rc1")
      refute Regex.match?(compiled, String.replace(identity, "github", "notion"))
      refute Regex.match?(compiled, String.replace(identity, "1.2.0", "1.2.1"))
      # the dots are literal, not wildcards
      refute Regex.match?(compiled, String.replace(identity, "/.github/", "/Xgithub/"))
    end

    test "errors when name or version is missing or blank" do
      assert {:error, {:missing_verifier_opt, :name}} =
               VerifierCosign.identity_regex(version: "1.0.0")

      assert {:error, {:missing_verifier_opt, :version}} =
               VerifierCosign.identity_regex(name: "github")

      assert {:error, {:missing_verifier_opt, :name}} =
               VerifierCosign.identity_regex(name: "", version: "1.0.0")
    end
  end

  describe "DistVerifierStub default-deny" do
    setup do
      DistVerifierStub.init()
      on_exit(&DistVerifierStub.cleanup/0)
      :ok
    end

    test "denies by default and only verifies an explicitly allowed name/version" do
      args = ["blob", "sig", "cert"]

      assert {:error, {:verification_denied, {"github", "1.2.0"}}} =
               apply(DistVerifierStub, :verify, args ++ [[name: "github", version: "1.2.0"]])

      DistVerifierStub.allow("github", "1.2.0")

      assert :ok = apply(DistVerifierStub, :verify, args ++ [[name: "github", version: "1.2.0"]])
      # a different version stays denied
      assert {:error, {:verification_denied, {"github", "9.9.9"}}} =
               apply(DistVerifierStub, :verify, args ++ [[name: "github", version: "9.9.9"]])
    end
  end

  describe "DistFetcherStub" do
    setup do
      tmp = FermixTestSupport.SafeRm.make_tmp_dir!("fermix-fetcher-stub")
      DistFetcherStub.init()

      on_exit(fn ->
        DistFetcherStub.cleanup()
        FermixTestSupport.SafeRm.rm_rf(tmp)
      end)

      %{tmp: tmp}
    end

    test "copies a configured fixture to the destination", %{tmp: tmp} do
      src = Path.join(tmp, "artifact.tar.gz")
      File.write!(src, "fixture-bytes")
      dest = Path.join(tmp, "out.tar.gz")
      DistFetcherStub.set("https://example.com/p", {:copy, src})

      assert :ok = DistFetcherStub.fetch("https://example.com/p", dest)
      assert File.read!(dest) == "fixture-bytes"
    end

    test "fails loud on an unconfigured URL", %{tmp: tmp} do
      dest = Path.join(tmp, "out.tar.gz")

      assert {:error, {:no_stub, "https://example.com/unknown"}} =
               DistFetcherStub.fetch("https://example.com/unknown", dest)
    end
  end
end
