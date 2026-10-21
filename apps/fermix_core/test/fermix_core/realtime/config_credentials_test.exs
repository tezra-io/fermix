defmodule FermixCore.Realtime.ConfigCredentialsTest do
  @moduledoc """
  The one voice credential resolver (M70 §06): every reader of the voice key,
  from startup to call construction, asks `Config.api_key/1`, so these cases
  pin which slot each engine reads and what never counts as a key.
  """

  # The resolver reads the providers block from the application environment,
  # which is global, so the cases own it and run alone.
  use ExUnit.Case, async: false

  alias FermixCore.Realtime.Config

  setup do
    providers = Application.get_env(:fermix_core, :providers)
    transcription = Application.get_env(:fermix_core, :transcription)

    on_exit(fn ->
      restore(:providers, providers)
      restore(:transcription, transcription)
    end)

    :ok
  end

  test "both OpenAI engines read the OpenAI provider key" do
    Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-voice"])

    for engine <- ~w(openai_realtime openai_live) do
      config = Config.normalize(engine: engine)

      assert Config.api_key(config) == {:ok, "sk-voice"}
      assert Config.api_key_present?(config)
    end
  end

  test "Grok reads the SpaceXAI provider key and never the OpenAI one" do
    Application.put_env(:fermix_core, :providers,
      openai: [api_key: "sk-voice"],
      xai: [api_key: "xai-voice"]
    )

    assert Config.api_key(Config.normalize(engine: "xai_realtime")) == {:ok, "xai-voice"}

    Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-voice"])
    config = Config.normalize(engine: "xai_realtime")

    assert Config.api_key(config) == {:error, {:missing_api_key, "xai"}}
    refute Config.api_key_present?(config)
  end

  # The documented realtime authentication is an API key; a SpaceXAI sign-in
  # lives in the auth store, which this resolver never reads.
  test "a SpaceXAI sign-in with no API key is no voice key" do
    Application.put_env(:fermix_core, :providers, xai: [auth_mode: :oauth, primary: true])

    assert Config.api_key(Config.normalize(engine: "xai_realtime")) ==
             {:error, {:missing_api_key, "xai"}}
  end

  # The voice-notes override is a different key for a different product.
  test "the transcription override is no voice key" do
    Application.put_env(:fermix_core, :providers, [])
    Application.put_env(:fermix_core, :transcription, backend: "xai", xai_api_key: "xai-notes")

    assert Config.api_key(Config.normalize(engine: "xai_realtime")) ==
             {:error, {:missing_api_key, "xai"}}
  end

  # A keychain reference that never resolved is a marker, not a key: sending it
  # would only earn a refusal at call time.
  test "an empty value and an unresolved secret reference count as absent for both providers" do
    for sentinel <- ["", "@keyring", "@file"],
        {provider, engine} <- [openai: "openai_live", xai: "xai_realtime"] do
      Application.put_env(:fermix_core, :providers, [{provider, [api_key: sentinel]}])
      config = Config.normalize(engine: engine)

      assert Config.api_key(config) == {:error, {:missing_api_key, Atom.to_string(provider)}}
      refute Config.api_key_present?(config)
    end
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
