defmodule FermixCore.Browser.ConfigTest do
  use ExUnit.Case, async: false

  alias FermixCore.Browser.Config

  setup do
    original = Application.get_env(:fermix_core, :browser)
    on_exit(fn -> restore(original) end)
    :ok
  end

  test "defaults include bounded live profiles and managed profiles" do
    Application.delete_env(:fermix_core, :browser)

    assert {:ok, config} = Config.current()
    assert config.default_profile == "fermix"
    assert config.max_live_profiles > 0
    assert config.idle_profile_ttl_ms > 0
    assert Map.fetch!(config.profiles, "fermix").headless == :auto
    assert Map.fetch!(config.profiles, "fermix_headless").headless == true
  end

  test "rejects invalid max_live_profiles" do
    Application.put_env(:fermix_core, :browser, max_live_profiles: 0)

    assert {:error, error} = Config.current()
    assert error.code == "invalid_config"
    assert error.message =~ "max_live_profiles"
  end

  test "requires existing-session profiles to provide cdp_url" do
    Application.put_env(:fermix_core, :browser,
      profiles: %{user: %{mode: :existing_session, headless: :auto, cdp_port: :auto}}
    )

    assert {:error, error} = Config.current()
    assert error.code == "invalid_config"
    assert error.message =~ "cdp_url"
  end

  test "rejects launch-mode overrides for existing-session profiles" do
    Application.put_env(:fermix_core, :browser,
      profiles: %{
        user: %{
          mode: :existing_session,
          cdp_url: "ws://127.0.0.1:9222/devtools/browser/test",
          headless: true,
          cdp_port: :auto
        }
      }
    )

    assert {:error, error} = Config.current()
    assert error.code == "invalid_config"
    assert error.message =~ "headless"
  end

  test "snapshot defaults are compact and bounded" do
    assert {:ok, defaults} = Config.snapshot_options(%{})
    assert defaults.interactive == true
    assert defaults.compact == true
    assert defaults.depth == 5
    assert defaults.include_urls == false
    assert defaults.max_children > 0
    assert defaults.max_chars > 0
  end

  # Whole-surface invariant, ENUMERATED FROM THE STRUCT rather than hand-spelled:
  # every integer tunable must both default positive and be rejected when set
  # non-positive. The previous hand-written field list meant a bound added later
  # (e.g. download_max_bytes) could skip validation with nothing failing.
  test "every integer tunable defaults positive and is validated" do
    Application.delete_env(:fermix_core, :browser)
    assert {:ok, defaults} = Config.current()

    fields =
      defaults
      |> Map.from_struct()
      |> Enum.filter(fn {_field, value} -> is_integer(value) end)
      |> Enum.map(fn {field, _value} -> field end)

    # Floor so a broken enumeration cannot pass vacuously.
    assert length(fields) > 20

    for field <- fields do
      assert Map.fetch!(defaults, field) > 0,
             "expected #{field} to default to a positive integer"

      Application.put_env(:fermix_core, :browser, [{field, 0}])

      assert {:error, error} = Config.current(), "expected #{field}: 0 to be rejected"
      assert error.code == "invalid_config"
      assert error.message =~ to_string(field)
    end
  end

  test "rejects a non-positive teardown timeout" do
    Application.put_env(:fermix_core, :browser, stop_grace_ms: 0)

    assert {:error, error} = Config.current()
    assert error.code == "invalid_config"
    assert error.message =~ "stop_grace_ms"
  end

  test "honors overridden system timeouts" do
    Application.put_env(:fermix_core, :browser, action_timeout_ms: 1234, wait_max_ms: 9999)

    assert {:ok, config} = Config.current()
    assert config.action_timeout_ms == 1234
    assert config.wait_max_ms == 9999
  end

  defp restore(nil), do: Application.delete_env(:fermix_core, :browser)
  defp restore(value), do: Application.put_env(:fermix_core, :browser, value)
end
