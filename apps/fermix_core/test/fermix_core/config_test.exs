defmodule FermixCore.ConfigTest do
  use ExUnit.Case, async: false

  alias FermixCore.Config

  # Every key these tests put or delete. Boot pins most of them (`config.exs`,
  # `config/test.exs`), and the suite runs every app in one VM, so each is put
  # back after every test, deleted only when it was absent: a key this file
  # removed would otherwise be read, or saved and restored as nil, by any later
  # test that relies on the pinned default.
  @touched [
    {:fermix_core, :providers},
    {:fermix_core, :max_conversation_history},
    {:fermix_core, :some_missing_key},
    {:fermix_channels, :telegram},
    {:fermix_channels, :signal},
    {:fermix_channels, :imessage}
  ]

  setup do
    saved = for {app, key} <- @touched, do: {app, key, Application.fetch_env(app, key)}
    on_exit(fn -> Enum.each(saved, &restore/1) end)
    :ok
  end

  defp restore({app, key, {:ok, value}}), do: Application.put_env(app, key, value)
  defp restore({app, key, :error}), do: Application.delete_env(app, key)

  describe "provider/1" do
    test "returns provider config when configured" do
      Application.put_env(:fermix_core, :providers,
        openai: [base_url: "https://api.openai.com/v1", default_model: "gpt-5.4-mini"]
      )

      assert {:ok, config} = Config.provider(:openai)
      assert config[:base_url] == "https://api.openai.com/v1"
      assert config[:default_model] == "gpt-5.4-mini"
    end

    test "returns error when provider not configured" do
      Application.put_env(:fermix_core, :providers, [])

      assert {:error, :not_configured} = Config.provider(:openai)
    end

    test "returns error when no providers config exists" do
      Application.delete_env(:fermix_core, :providers)

      assert {:error, :not_configured} = Config.provider(:openai)
    end
  end

  describe "provider_api_key/1" do
    test "returns API key when configured" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-test-123"])

      assert {:ok, "sk-test-123"} = Config.provider_api_key(:openai)
    end

    test "returns error when provider exists but no api_key" do
      Application.put_env(:fermix_core, :providers,
        openai: [base_url: "https://api.openai.com/v1"]
      )

      assert {:error, :not_configured} = Config.provider_api_key(:openai)
    end

    test "returns error when provider not configured" do
      Application.delete_env(:fermix_core, :providers)

      assert {:error, :not_configured} = Config.provider_api_key(:anthropic)
    end

    test "returns error for empty string api key" do
      Application.put_env(:fermix_core, :providers, openai: [api_key: ""])

      assert {:error, :not_configured} = Config.provider_api_key(:openai)
    end
  end

  describe "channel/1" do
    test "returns channel config when configured" do
      Application.put_env(:fermix_channels, :telegram,
        enabled: true,
        webhook_path: "/webhook/telegram"
      )

      assert {:ok, config} = Config.channel(:telegram)
      assert config[:enabled] == true
      assert config[:webhook_path] == "/webhook/telegram"
    end

    test "returns error when channel not configured" do
      Application.delete_env(:fermix_channels, :telegram)

      assert {:error, :not_configured} = Config.channel(:telegram)
    end
  end

  describe "channel command and ingress ids" do
    test "declares paired-device ingress as distinct from config allowlists" do
      assert Config.channel_ingress_authority(:mobile) == :paired_device
      assert Config.channel_ingress_authority(:telegram) == :config_allowlist
      assert Config.channel_ingress_authority(:unknown) == :none
      assert Config.channel_ingress_user_ids(:mobile) == []
    end

    test "defaults ingress allowlist to owner_user_id when channel allowlist is absent" do
      Application.put_env(:fermix_channels, :telegram, owner_user_id: "111")

      assert Config.channel_ingress_user_ids(:telegram) == ["111"]
      assert Config.channel_command_owner_user_id(:telegram) == "111"
    end

    test "preserves explicitly configured ingress allowlists" do
      Application.put_env(:fermix_channels, :telegram,
        owner_user_id: "111",
        allowed_user_ids: []
      )

      assert Config.channel_ingress_user_ids(:telegram) == []
    end

    test "derives command owner from a single explicit ingress id" do
      Application.put_env(:fermix_channels, :telegram, allowed_user_ids: [111])
      Application.put_env(:fermix_channels, :signal, allowed_sender_ids: ["+15551234567"])

      assert Config.channel_command_owner_user_id(:telegram) == "111"
      assert Config.channel_command_owner_user_id(:signal) == "+15551234567"
    end

    # M54 §9.2: iMessage takes the M53 OWN-3 semantics from its first release —
    # the ingress list is the owner AND the guests, so an empty guest list means
    # "no guests", never "no owner".
    test "imessage ingress is the owner and the guests, and an empty guest list keeps the owner" do
      Application.put_env(:fermix_channels, :imessage,
        owner_user_id: "+15551234567",
        allowed_sender_ids: []
      )

      assert Config.channel_ingress_authority(:imessage) == :config_allowlist
      assert Config.channel_ingress_user_ids(:imessage) == ["+15551234567"]

      Application.put_env(:fermix_channels, :imessage,
        owner_user_id: "+15551234567",
        allowed_sender_ids: ["friend@example.com", "+15551234567"]
      )

      assert Config.channel_ingress_user_ids(:imessage) == ["+15551234567", "friend@example.com"]
      assert Config.channel_explicit_owner_user_id(:imessage) == "+15551234567"
    end

    test "does not derive command owner from empty or multi-user ingress allowlists" do
      Application.put_env(:fermix_channels, :telegram, allowed_user_ids: [])
      assert Config.channel_command_owner_user_id(:telegram) == nil

      Application.put_env(:fermix_channels, :telegram, allowed_user_ids: ["111", "222"])
      assert Config.channel_command_owner_user_id(:telegram) == nil
    end
  end

  describe "get/2" do
    test "returns configured value" do
      Application.put_env(:fermix_core, :max_conversation_history, 50)

      assert {:ok, 50} = Config.get(:max_conversation_history)
    end

    test "returns default when not configured" do
      Application.delete_env(:fermix_core, :max_conversation_history)

      assert {:ok, 25} = Config.get(:max_conversation_history, 25)
    end

    test "returns error with no default when not configured" do
      Application.delete_env(:fermix_core, :some_missing_key)

      assert {:error, :not_configured} = Config.get(:some_missing_key)
    end
  end
end
