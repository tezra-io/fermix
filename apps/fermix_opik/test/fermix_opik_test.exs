defmodule FermixOpikTest do
  use ExUnit.Case, async: false

  setup do
    saved = System.get_env("FERMIX_OPIK_ENABLED")
    saved_url = System.get_env("FERMIX_OPIK_BASE_URL")

    on_exit(fn ->
      restore("FERMIX_OPIK_ENABLED", saved)
      restore("FERMIX_OPIK_BASE_URL", saved_url)
    end)

    :ok
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)

  test "enabled? honors the env var over config" do
    System.delete_env("FERMIX_OPIK_ENABLED")
    refute FermixOpik.enabled?()

    System.put_env("FERMIX_OPIK_ENABLED", "1")
    assert FermixOpik.enabled?()

    System.put_env("FERMIX_OPIK_ENABLED", "false")
    refute FermixOpik.enabled?()
  end

  test "client_config takes base_url from the env" do
    System.put_env("FERMIX_OPIK_BASE_URL", "http://localhost:9999/api")
    assert FermixOpik.client_config().base_url == "http://localhost:9999/api"
  end

  test "defaults to a local Opik with no auth headers" do
    System.delete_env("FERMIX_OPIK_BASE_URL")
    config = FermixOpik.client_config()
    assert config.base_url == "http://localhost:5173/api"
    assert config.api_key == nil
    assert config.workspace == nil
  end
end
