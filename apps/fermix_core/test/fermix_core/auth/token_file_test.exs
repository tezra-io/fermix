defmodule FermixCore.Auth.TokenFileTest do
  @moduledoc """
  The daemon-owned access-token projection a local `mcp` plugin child reads
  (M8 §9.3). These assertions ARE the contract the vendored Go helper is
  written against: the key names, the ISO 8601 expiry, the nullable region,
  the monotonic generation, and the `0600` mode inside the store's `0700`
  `run/` directory.
  """

  use ExUnit.Case, async: true

  import Bitwise, only: [&&&: 2]

  alias FermixCore.Auth.TokenFile
  alias FermixTestSupport.SafeRm

  setup do
    dir = SafeRm.make_tmp_dir!("token-file")
    File.chmod!(dir, 0o700)
    on_exit(fn -> SafeRm.rm_rf!(dir) end)

    %{dir: dir, path: Path.join(dir, "tesla_primary.token")}
  end

  defp projection(overrides \\ %{}) do
    Map.merge(
      %{
        access_token: "at-canary-do-not-leak",
        expires_at: ~U[2026-09-13 09:41:07Z],
        region: "eu",
        auth_profile: "tesla:primary",
        generation: 3
      },
      overrides
    )
  end

  defp mode(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    mode &&& 0o777
  end

  describe "write/2" do
    test "writes exactly the five documented keys", %{path: path} do
      assert :ok = TokenFile.write(path, projection())

      assert Jason.decode!(File.read!(path)) == %{
               "access_token" => "at-canary-do-not-leak",
               "expires_at" => "2026-09-13T09:41:07Z",
               "region" => "eu",
               "auth_profile" => "tesla:primary",
               "generation" => 3
             }
    end

    test "the file is 0600 inside the 0700 directory", %{path: path, dir: dir} do
      assert :ok = TokenFile.write(path, projection())

      assert mode(path) == 0o600
      assert mode(dir) == 0o700
    end

    test "an absent expiry and an absent region are null, never omitted", %{path: path} do
      assert :ok = TokenFile.write(path, projection(%{expires_at: nil, region: nil}))

      decoded = Jason.decode!(File.read!(path))

      assert decoded["expires_at"] == nil
      assert decoded["region"] == nil
      assert Map.has_key?(decoded, "expires_at")
      assert Map.has_key?(decoded, "region")
    end

    test "a rewrite replaces the content and leaves no temp file behind", %{
      path: path,
      dir: dir
    } do
      assert :ok = TokenFile.write(path, projection())
      assert :ok = TokenFile.write(path, projection(%{access_token: "at-2", generation: 4}))

      decoded = Jason.decode!(File.read!(path))
      assert decoded["access_token"] == "at-2"
      assert decoded["generation"] == 4
      assert mode(path) == 0o600

      assert File.ls!(dir) |> Enum.reject(&String.starts_with?(&1, ".")) == [
               "tesla_primary.token"
             ]
    end

    # The plugin store owns `run/` and creates it 0700. Re-creating it here would
    # be a second owner that could make it under the wrong mode, so a missing
    # directory is reported instead.
    test "a missing directory is reported, never created", %{dir: dir} do
      path = Path.join([dir, "absent", "tesla_primary.token"])

      assert {:error, :enoent} = TokenFile.write(path, projection())
      refute File.dir?(Path.join(dir, "absent"))
    end

    test "a blank access token is a caller bug, not a file to write", %{path: path} do
      assert_raise FunctionClauseError, fn ->
        TokenFile.write(path, projection(%{access_token: ""}))
      end

      refute File.exists?(path)
    end
  end

  describe "delete/1" do
    test "removes the projection", %{path: path} do
      assert :ok = TokenFile.write(path, projection())
      assert :ok = TokenFile.delete(path)
      refute File.exists?(path)
    end

    test "an already-absent projection is the requested state, not an error", %{path: path} do
      assert :ok = TokenFile.delete(path)
    end
  end
end
