defmodule Fermix.CLI.VersionSkewTest do
  @moduledoc """
  The one typed comparison of installed and running engine identity (M38 §9.2).

  Every case builds two identity maps, because that is what the comparator takes
  now: a version string alone cannot express a conflict, and inferring skew from
  product versions is the defect §9.2 forbids for a published engine.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.VersionSkew

  @packaged %{
    "engine_id" => "fermix-core",
    "product_version" => "1.2.3",
    "build_id" => "release-9",
    "source_commit" => String.duplicate("a", 40),
    "distribution_identity" => "linux_package",
    "artifact_target" => "linux_x86_64",
    "architecture" => "x86_64"
  }

  @standalone %{
    "engine_id" => "fermix-core",
    "product_version" => "0.5.7",
    "build_id" => nil,
    "source_commit" => nil,
    "distribution_identity" => "standalone",
    "artifact_target" => nil,
    "architecture" => "arm64"
  }

  describe "compare/2 for a published engine" do
    test "matching build ids are aligned" do
      assert VersionSkew.compare(@packaged, @packaged) == :aligned
    end

    test "differing build ids call for a restart" do
      running = %{@packaged | "build_id" => "release-8"}

      assert VersionSkew.compare(@packaged, running) == :pending_restart
    end

    # §9.2: a build id is compared with a build id. Two product versions that
    # disagree are display values, and a published engine that cannot produce a
    # build id is unknown rather than skewed.
    test "an absent build id on either side is unknown, never read off the version" do
      older = %{@packaged | "build_id" => nil, "product_version" => "1.0.0"}

      assert VersionSkew.compare(@packaged, older) == :unknown
      assert VersionSkew.compare(%{@packaged | "build_id" => nil}, @packaged) == :unknown
    end

    test "a different distribution or architecture is an ownership conflict" do
      assert VersionSkew.compare(@packaged, %{@packaged | "distribution_identity" => "standalone"}) ==
               :ownership_conflict

      assert VersionSkew.compare(@packaged, %{@packaged | "architecture" => "arm64"}) ==
               :ownership_conflict
    end

    # The conflict is decided first: a foreign daemon whose build id happens to
    # match is still a foreign daemon.
    test "an ownership conflict outranks a missing build id" do
      foreign = %{@packaged | "distribution_identity" => "macos_app", "build_id" => nil}

      assert VersionSkew.compare(@packaged, foreign) == :ownership_conflict
    end
  end

  # A standalone binary is stamped with no build id at all — the release job
  # supplies none — so its product version IS its generation. That is a second
  # distribution configuration, decided by the identity's own distribution
  # field, not a guess made when a build id happens to be absent.
  describe "compare/2 for a standalone engine" do
    test "the same product version is aligned" do
      assert VersionSkew.compare(@standalone, @standalone) == :aligned
    end

    test "the brew-upgrade state is a pending restart" do
      running = %{@standalone | "product_version" => "0.5.6"}

      assert VersionSkew.compare(@standalone, running) == :pending_restart
    end

    test "a daemon that reports no product version is unknown" do
      running = %{@standalone | "product_version" => nil}

      assert VersionSkew.compare(@standalone, running) == :unknown
    end
  end

  test "compare/2 with no running identity is not_running" do
    assert VersionSkew.compare(@packaged, nil) == :not_running
    assert VersionSkew.compare(@standalone, nil) == :not_running
  end

  describe "note/2" do
    test "an aligned or absent daemon has nothing to say" do
      assert VersionSkew.note(:aligned, installed: "1.2.3", running: "1.2.3") == nil
      assert VersionSkew.note(:not_running, installed: "1.2.3", running: nil) == nil
    end

    test "a pending restart names both versions and the restart" do
      note = VersionSkew.note(:pending_restart, installed: "0.5.7", running: "0.5.6")

      assert note =~ "daemon is running 0.5.6"
      assert note =~ "installed binary is 0.5.7"
      assert note =~ "`fermix restart`"
    end

    test "unknown explains the missing identity rather than claiming skew" do
      note = VersionSkew.note(:unknown, installed: "1.2.3", running: "1.0.0")

      assert note =~ "build id"
      refute note =~ "`fermix restart`"
    end

    test "an ownership conflict says the answering daemon is a different Fermix" do
      note = VersionSkew.note(:ownership_conflict, installed: "1.2.3", running: "1.2.3")

      assert note =~ "different Fermix"
      refute note =~ "`fermix restart`"
    end

    test "the installed version defaults to this build's own" do
      vsn = to_string(Application.spec(:fermix_core, :vsn))

      assert VersionSkew.note(:pending_restart, running: "0.0.1") =~ "installed binary is #{vsn}"
    end
  end

  # The installed side of every real comparison is this build's own identity,
  # and a comparison against itself must be aligned or every surface warns.
  test "this build compared with itself is aligned" do
    identity = FermixCore.BuildInfo.public_identity()

    assert VersionSkew.compare(identity, identity) == :aligned
  end
end
