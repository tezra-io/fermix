defmodule FermixCore.PhoneCalls.ConfigTest do
  # `normalize/1`, `validate/1` and `to_keyword/1` take explicit input. The
  # tests of `get/0` and the key resolvers set the application environment they
  # read and restore it, so the module runs alone.
  use ExUnit.Case, async: false

  alias FermixCore.PhoneCalls.CarrierProfile
  alias FermixCore.PhoneCalls.Config
  alias FermixCore.Realtime.Config, as: RealtimeConfig

  # Invented values, in the 555-01XX range NANPA reserves for fiction.
  @caller "+14155550142"

  describe "normalize/1" do
    test "an absent or empty section is the disabled default with the Live default voice" do
      for raw <- [nil, [], %{}] do
        assert %Config{
                 enabled: false,
                 voice: voice,
                 caller_number: nil,
                 sip_username: nil,
                 sip_password: nil
               } = Config.normalize(raw)

        assert voice == RealtimeConfig.default_voice(CarrierProfile.voice_engine())
      end
    end

    test "reads TOML string keys, atom keys and a keyword" do
      expected = %Config{
        enabled: true,
        voice: "cedar",
        caller_number: @caller,
        sip_username: "fermixtrunk01",
        sip_password: nil
      }

      toml = %{
        "enabled" => true,
        "voice" => "cedar",
        "caller_number" => @caller,
        "sip_username" => "fermixtrunk01"
      }

      assert Config.normalize(toml) == expected

      assert Config.normalize(%{
               enabled: true,
               voice: "cedar",
               caller_number: @caller,
               sip_username: "fermixtrunk01"
             }) == expected

      assert Config.normalize(
               enabled: true,
               voice: "cedar",
               caller_number: @caller,
               sip_username: "fermixtrunk01"
             ) == expected
    end

    test "a blank optional value is unset, so a cleared field clears" do
      assert %Config{caller_number: nil, sip_username: nil, sip_password: nil} =
               Config.normalize(caller_number: "  ", sip_username: "", sip_password: "")
    end

    test "every GPT-Live voice the engine ships is accepted, and nothing else" do
      for voice <- RealtimeConfig.valid_voices(CarrierProfile.voice_engine()) do
        assert Config.normalize(voice: voice).voice == voice
      end

      refute "eve" in RealtimeConfig.valid_voices(CarrierProfile.voice_engine())
      assert {:error, [{:voice, :unknown_voice}]} = Config.validate(voice: "eve")
    end

    test "raises naming the section, each key and its reason" do
      error =
        assert_raise ArgumentError, fn ->
          Config.normalize(%{"enabled" => "yes", "voice" => "eve", "trunk" => "sip.example"})
        end

      assert error.message =~ "[fermix_core.phone_calls]"
      assert error.message =~ "enabled"
      assert error.message =~ "voice"
      assert error.message =~ "trunk"
    end

    test "is idempotent over its own inverse" do
      config =
        Config.normalize(
          enabled: true,
          voice: "cedar",
          caller_number: @caller,
          sip_username: "fermixtrunk01",
          sip_password: "@keyring"
        )

      assert config |> Config.to_keyword() |> Config.normalize() == config
    end
  end

  describe "validate/1 reports every problem, each with its own reason" do
    test "type and value classes" do
      assert {:error, problems} =
               Config.validate(%{
                 "enabled" => 1,
                 "voice" => 7,
                 "caller_number" => "4155550142",
                 "sip_username" => "trunk\nuser",
                 "sip_password" => String.duplicate("p", 4097),
                 "provider_url" => "sips:sip.example.com"
               })

      assert {:enabled, :not_boolean} in problems
      assert {:voice, :not_a_string} in problems
      assert {:caller_number, :not_e164} in problems
      assert {:sip_username, :control_characters} in problems
      assert {:sip_password, :too_long} in problems
      assert {"provider_url", :unknown_key} in problems
      assert length(problems) == 6
    end

    test "a caller number outside the US states and DC, or a special number, is refused" do
      assert Config.validate(caller_number: "+14165550142") ==
               {:error, [{:caller_number, :destination_not_us}]}

      assert Config.validate(caller_number: "+18005550142") ==
               {:error, [{:caller_number, :emergency_or_special_number}]}

      assert Config.validate(caller_number: "+11125550142") ==
               {:error, [{:caller_number, :not_nanp_number}]}
    end

    test "the trunk username follows the provider's digest bounds" do
      assert {:error, [{:sip_username, :too_long}]} =
               Config.validate(sip_username: String.duplicate("u", 257))

      assert {:ok, %Config{}} = Config.validate(sip_username: String.duplicate("u", 256))

      assert {:error, [{:sip_password, :control_characters}]} =
               Config.validate(sip_password: "pass\u0000word")
    end

    test "a valid section" do
      assert {:ok, %Config{enabled: true, caller_number: @caller}} =
               Config.validate(enabled: true, caller_number: @caller)
    end
  end

  describe "to_keyword/1" do
    test "writes only what is set, so the default section renders nothing" do
      assert Config.to_keyword(Config.normalize(nil)) == []
    end

    test "writes every set key in a fixed order" do
      config = %Config{
        enabled: true,
        voice: "cedar",
        caller_number: @caller,
        sip_username: "fermixtrunk01",
        sip_password: "@keyring"
      }

      assert Config.to_keyword(config) == [
               enabled: true,
               voice: "cedar",
               caller_number: @caller,
               sip_username: "fermixtrunk01",
               sip_password: "@keyring"
             ]
    end

    test "the default voice is not pinned into the file" do
      default = RealtimeConfig.default_voice(CarrierProfile.voice_engine())
      assert Config.to_keyword(struct!(Config.normalize(nil), voice: default)) == []
    end
  end

  test "the password never appears when a config is inspected" do
    config = Config.normalize(sip_password: "invented-trunk-password")
    refute inspect(config) =~ "invented-trunk-password"
  end

  test "config_keys/0 is exactly the section's settable surface" do
    assert Config.config_keys() == [
             :enabled,
             :voice,
             :caller_number,
             :sip_username,
             :sip_password
           ]
  end

  describe "reading the running settings" do
    setup do
      phone_calls = Application.fetch_env(:fermix_core, :phone_calls)
      providers = Application.fetch_env(:fermix_core, :providers)

      on_exit(fn ->
        restore(:phone_calls, phone_calls)
        restore(:providers, providers)
      end)

      :ok
    end

    test "get/0 and enabled?/0 read the section from application environment" do
      Application.put_env(:fermix_core, :phone_calls, [])
      refute Config.enabled?()

      Application.put_env(:fermix_core, :phone_calls, enabled: true, caller_number: @caller)
      assert %Config{enabled: true, caller_number: @caller} = Config.get()
      assert Config.enabled?()
    end

    test "sip_password/1 is the stored password, never a sentinel or a blank" do
      assert Config.sip_password(struct!(Config.normalize(nil), sip_password: "invented-pw")) ==
               {:ok, "invented-pw"}

      for unresolved <- [nil, "@keyring", "@file"] do
        assert Config.sip_password(struct!(Config.normalize(nil), sip_password: unresolved)) ==
                 {:error, :missing_sip_password}
      end
    end

    test "openai_api_key/0 reads the OpenAI provider's key, never SpaceXAI's" do
      Application.put_env(:fermix_core, :providers, xai: [api_key: "xai-invented"])
      assert Config.openai_api_key() == {:error, :missing_openai_api_key}

      Application.put_env(:fermix_core, :providers,
        openai: [api_key: "@keyring"],
        xai: [api_key: "xai-invented"]
      )

      assert Config.openai_api_key() == {:error, :missing_openai_api_key}

      Application.put_env(:fermix_core, :providers, openai: [api_key: "sk-invented"])
      assert Config.openai_api_key() == {:ok, "sk-invented"}
    end
  end

  describe "the certified carrier profile" do
    test "is the Telnyx credential connection over TLS, never an owner-typed host" do
      assert CarrierProfile.id() == "telnyx_credential_v1"
      assert CarrierProfile.trunk_address() == "sips:sip.telnyx.com:5061"
      refute :trunk_address in Config.config_keys()
      refute :provider_url in Config.config_keys()
    end

    test "names a GPT-Live model the engine ships" do
      assert CarrierProfile.model() == "gpt-live-1"
      assert CarrierProfile.model() in RealtimeConfig.valid_models(CarrierProfile.voice_engine())
    end
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:fermix_core, key, value)
  defp restore(key, :error), do: Application.delete_env(:fermix_core, key)
end
