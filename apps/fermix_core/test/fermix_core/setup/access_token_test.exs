defmodule FermixCore.Setup.AccessTokenTest do
  use ExUnit.Case, async: false

  alias FermixCore.Setup.AccessToken

  setup do
    previous_home = System.get_env("FERMIX_HOME")
    home = FermixTestSupport.SafeRm.make_tmp_dir!("setup-token")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      FermixTestSupport.SafeRm.rm_rf!(home)
    end)

    %{home: home}
  end

  test "ensure_setup_token creates a 0600 persistent token and reuses it", %{home: home} do
    assert {:ok, token} = AccessToken.ensure_setup_token()
    assert is_binary(token)
    assert byte_size(token) >= 32

    path = Path.join(home, "setup-token")
    assert File.read!(path) == token
    assert file_mode(path) == 0o600

    assert {:ok, ^token} = AccessToken.ensure_setup_token()
  end

  test "rotate_setup_token replaces the persistent token and clears pending launch state", %{
    home: home
  } do
    assert {:ok, original} = AccessToken.ensure_setup_token()
    assert {:ok, %{token: launch_token}} = AccessToken.mint_launch_token()

    assert File.exists?(Path.join(home, "setup-launch-token.json"))
    assert is_binary(launch_token)

    assert {:ok, rotated} = AccessToken.rotate_setup_token()
    assert rotated != original
    refute File.exists?(Path.join(home, "setup-launch-token.json"))
  end

  test "minted launch tokens authorize once and then expire from URL reuse" do
    assert {:ok, %{token: launch_token}} = AccessToken.mint_launch_token()

    assert {:ok, fingerprint} = AccessToken.consume_launch_token(launch_token)
    assert AccessToken.session_authorized?(fingerprint)
    assert {:error, :missing_launch_token} = AccessToken.consume_launch_token(launch_token)
  end

  test "expired launch tokens are rejected and removed" do
    assert {:ok, %{token: launch_token}} =
             AccessToken.mint_launch_token(now_ms: 1_000, ttl_ms: 10)

    assert {:error, :expired_launch_token} =
             AccessToken.consume_launch_token(launch_token, now_ms: 1_011)

    assert {:error, :missing_launch_token} =
             AccessToken.consume_launch_token(launch_token, now_ms: 1_011)
  end

  test "rotating the setup token invalidates existing setup sessions" do
    assert {:ok, %{token: launch_token}} = AccessToken.mint_launch_token()
    assert {:ok, fingerprint} = AccessToken.consume_launch_token(launch_token)
    assert AccessToken.session_authorized?(fingerprint)

    assert {:ok, _new_token} = AccessToken.rotate_setup_token()
    refute AccessToken.session_authorized?(fingerprint)
  end

  defp file_mode(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end
end
