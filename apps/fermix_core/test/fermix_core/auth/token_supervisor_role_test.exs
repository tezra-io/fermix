defmodule FermixCore.Auth.TokenSupervisorRoleTest do
  # M75 D5: after a move the token file on this host is a retired copy, and a
  # rotating refresh token has one live owner, so a device-role engine starts
  # no token manager, refreshes nothing and only reports what is stored.
  #
  # async: false: mutates FERMIX_HOME so the Store's default path is this test's.
  use ExUnit.Case, async: false

  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenSupervisor
  alias FermixTestSupport.SafeRm

  @device %{role: :device, primary: "aws i-0f3b1c"}
  @refusal {:error,
            {:device_role, "This engine runs in the device role; the primary is aws i-0f3b1c."}}
  @profile "anthropic_oauth"

  setup do
    home = SafeRm.make_tmp_dir!("token_supervisor_role")
    prior = System.get_env("FERMIX_HOME")
    System.put_env("FERMIX_HOME", home)

    on_exit(fn ->
      case prior do
        nil -> System.delete_env("FERMIX_HOME")
        value -> System.put_env("FERMIX_HOME", value)
      end

      SafeRm.rm_rf!(home)
    end)

    # Due for a refresh: a primary would refresh it on first use.
    entry = %{
      auth_mode: "claude_code_import",
      provider: "anthropic",
      tokens: %{access_token: "old_at", refresh_token: "old_rt"},
      expires_at: DateTime.add(DateTime.utc_now(), 30, :second),
      last_refresh: nil
    }

    :ok = Store.write(@profile, entry)
    {:ok, stored} = Store.read(@profile)
    %{stored: stored}
  end

  defp managed?, do: Registry.lookup(FermixCore.Auth.TokenRegistry, @profile) != []

  test "status reports the stored state and starts no manager", %{stored: stored} do
    assert TokenSupervisor.status(@profile, engine_role: @device) ==
             {:ok, %{auth_profile: @profile, loaded?: true, expires_at: stored.expires_at}}

    refute managed?()
  end

  test "a token, a refresh and a reload are refused by name and nothing is refreshed",
       %{stored: stored} do
    assert TokenSupervisor.get_token(@profile, engine_role: @device) == @refusal
    assert TokenSupervisor.refresh(@profile, engine_role: @device) == @refusal
    assert TokenSupervisor.reload(@profile, engine_role: @device) == @refusal

    refute managed?()
    assert Store.read(@profile) == {:ok, stored}
  end

  test "a plugin's token file is refused by name" do
    path = Path.join(System.get_env("FERMIX_HOME"), "token")

    assert TokenSupervisor.enable_token_file(@profile, path, engine_role: @device) == @refusal
    refute File.exists?(path)
    refute managed?()
  end
end
