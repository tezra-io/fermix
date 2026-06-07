defmodule FermixCore.Providers.PrimaryConfigTest do
  use ExUnit.Case, async: false

  alias FermixCore.Providers.PrimaryConfig

  setup do
    providers = Application.get_env(:fermix_core, :providers, [])
    agent = Application.get_env(:fermix_core, :agent, [])

    on_exit(fn ->
      Application.put_env(:fermix_core, :providers, providers)
      Application.put_env(:fermix_core, :agent, agent)
    end)

    :ok
  end

  test "no primary flags and no legacy provider default to :openai" do
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :agent, [])

    assert PrimaryConfig.primary() == {:ok, :openai}
  end

  test "no primary flags fall back to legacy [fermix_core.agent].provider" do
    Application.put_env(:fermix_core, :providers, anthropic: [api_key: "sk-ant"])
    Application.put_env(:fermix_core, :agent, provider: :anthropic)

    assert PrimaryConfig.primary() == {:ok, :anthropic}
  end

  test "a primary flag wins over the legacy agent provider" do
    Application.put_env(:fermix_core, :providers,
      anthropic: [primary: true, api_key: "sk-ant"],
      openai: [api_key: "sk-x"]
    )

    Application.put_env(:fermix_core, :agent, provider: :openai)

    assert PrimaryConfig.primary() == {:ok, :anthropic}
  end

  test "primary: false flags are not treated as primary" do
    Application.put_env(:fermix_core, :providers,
      openai: [primary: false, api_key: "sk-x"],
      xai: [primary: false]
    )

    Application.put_env(:fermix_core, :agent, [])

    assert PrimaryConfig.primary() == {:ok, :openai}
  end

  test "more than one primary returns {:error, :multiple_primary}" do
    Application.put_env(:fermix_core, :providers,
      openai: [primary: true, api_key: "sk-x"],
      xai: [primary: true, api_key: "xai-key"]
    )

    Application.put_env(:fermix_core, :agent, [])

    assert PrimaryConfig.primary() == {:error, :multiple_primary}
  end
end
