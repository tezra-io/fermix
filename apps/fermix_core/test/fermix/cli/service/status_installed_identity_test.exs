defmodule Fermix.CLI.Service.StatusInstalledIdentityTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Service.Status

  @compiled %{
    "build_id" => "dev-ecf56e55ead5-dirty",
    "product_version" => "0.10.5",
    "distribution_identity" => "linux_package",
    "architecture" => "x86_64"
  }

  @manifest %{
    "build_id" => "dev-ecf56e55ead5-dirty-b9e2105a",
    "product_version" => "0.10.5",
    "distribution_identity" => "linux_package",
    "architecture" => "x86_64"
  }

  describe "installed/2" do
    test "publishes the identity the package put on disk, not the answering code's" do
      installed = Status.installed(@compiled, {:ok, @manifest})

      assert installed["build_id"] == "dev-ecf56e55ead5-dirty-b9e2105a"
      assert installed["integrity"] == "mismatched"
    end

    # The defect this pins: a stale engine answered with its own compiled id on
    # both sides of the comparison, so alignment said "aligned" while integrity
    # said "mismatched" — and the owner, running an engine they had already
    # replaced, was told everything was in order.
    test "a mismatched integrity can never read as aligned" do
      installed = Status.installed(@compiled, {:ok, @manifest})

      assert installed["integrity"] == "mismatched"
      assert Status.alignment(installed, @compiled) == "pending_restart"
    end

    test "a manifest that agrees leaves the identity alone and verifies it" do
      installed = Status.installed(@compiled, {:ok, @compiled})

      assert installed["build_id"] == @compiled["build_id"]
      assert installed["integrity"] == "verified"
      assert Status.alignment(installed, @compiled) == "aligned"
    end

    test "an unreadable manifest falls back to the compiled identity and says so" do
      installed = Status.installed(@compiled, {:error, :enoent})

      assert installed["build_id"] == @compiled["build_id"]
      assert installed["integrity"] == "unreadable"
    end

    test "a manifest missing a key keeps the build's own value for it" do
      installed = Status.installed(@compiled, {:ok, Map.delete(@manifest, "architecture")})

      assert installed["architecture"] == "x86_64"
      assert installed["build_id"] == @manifest["build_id"]
    end
  end
end
