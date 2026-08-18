defmodule FermixCore.Meetings.ConfigTest do
  # async: false — every test establishes the `:meetings` and `:personalization`
  # app env it reads, and restores whatever was there before.
  use ExUnit.Case, async: false

  alias FermixCore.Meetings.Config

  setup do
    meetings = Application.get_env(:fermix_core, :meetings)
    personalization = Application.get_env(:fermix_core, :personalization)

    on_exit(fn ->
      restore(:meetings, meetings)
      restore(:personalization, personalization)
    end)

    :ok
  end

  describe "load/0 defaults" do
    test "an absent section yields the shipped posture" do
      Application.delete_env(:fermix_core, :meetings)
      Application.delete_env(:fermix_core, :personalization)

      config = Config.load()

      assert config.enabled == false
      assert config.bot_name == "Fermix Notetaker"
      assert config.announce == true
      assert config.transcription_backend == ""
      assert config.retain_audio == false
      assert config.zoom_account_id == ""
      assert config.zoom_client_id == ""
      assert config.zoom_client_secret == ""
      assert config.zoom_ws_subscription_id == ""
    end

    test "blank and wrongly-typed values fall to the same defaults" do
      Application.put_env(:fermix_core, :meetings,
        enabled: "yes",
        bot_name: "   ",
        announce: nil,
        retain_audio: 1
      )

      config = Config.load()

      assert config.enabled == false
      assert config.bot_name == "Fermix Notetaker"
      assert config.announce == true
      assert config.retain_audio == false
    end
  end

  describe "load/0 configured values" do
    test "reads each key" do
      Application.put_env(:fermix_core, :meetings,
        enabled: true,
        bot_name: " Ada's Notetaker ",
        announce: false,
        announce_message: "Recording for the team.",
        transcription_backend: "deepgram",
        retain_audio: true,
        zoom_account_id: "acct_1",
        zoom_client_id: "client_1",
        zoom_client_secret: "secret_1",
        zoom_ws_subscription_id: "sub_1"
      )

      config = Config.load()

      assert config.enabled == true
      assert config.bot_name == "Ada's Notetaker"
      assert config.announce == false
      assert config.announce_message == "Recording for the team."
      assert config.transcription_backend == "deepgram"
      assert config.retain_audio == true
      assert config.zoom_account_id == "acct_1"
      assert config.zoom_ws_subscription_id == "sub_1"
    end

    test "enabled?/0 reports the toggle alone" do
      Application.put_env(:fermix_core, :meetings, enabled: true)
      assert Config.enabled?()

      Application.put_env(:fermix_core, :meetings, enabled: false)
      refute Config.enabled?()
    end
  end

  describe "announce message" do
    test "a blank configured message resolves to the built-in template" do
      Application.put_env(:fermix_core, :meetings, bot_name: "Ada's Notetaker")
      Application.put_env(:fermix_core, :personalization, user_name: "Ada")

      assert Config.load().announce_message ==
               "👋 Ada's Notetaker here — Ada's AI notetaker. " <>
                 "Taking text notes only (no audio kept); the host can remove me anytime."
    end

    test "falls back to a neutral owner name when personalization has none" do
      Application.put_env(:fermix_core, :meetings, [])
      Application.put_env(:fermix_core, :personalization, user_name: nil)

      assert Config.load().announce_message =~ "the operator's AI notetaker"
      assert Config.load().announce_message =~ "Fermix Notetaker here"
    end

    test "a configured message is used verbatim" do
      Application.put_env(:fermix_core, :meetings, announce_message: "Notes are being taken.")
      Application.put_env(:fermix_core, :personalization, user_name: "Ada")

      assert Config.load().announce_message == "Notes are being taken."
    end
  end

  describe "rtms_configured?/0" do
    test "is true only with all four credentials resolved" do
      Application.put_env(:fermix_core, :meetings, rtms_credentials())

      assert Config.rtms_configured?()
    end

    test "is false when any credential is blank" do
      for key <- [
            :zoom_account_id,
            :zoom_client_id,
            :zoom_client_secret,
            :zoom_ws_subscription_id
          ] do
        Application.put_env(
          :fermix_core,
          :meetings,
          Keyword.put(rtms_credentials(), key, "")
        )

        refute Config.rtms_configured?(), "expected #{key} = \"\" to refuse"
      end
    end

    test "is false when the secret never resolved out of the keyring" do
      Application.put_env(
        :fermix_core,
        :meetings,
        Keyword.put(rtms_credentials(), :zoom_client_secret, "@keyring")
      )

      refute Config.rtms_configured?()
    end
  end

  describe "inspect/1 redaction" do
    test "the Zoom client secret never renders in an inspected config" do
      Application.put_env(:fermix_core, :meetings, rtms_credentials())

      rendered = inspect(Config.load())

      refute rendered =~ "secret_1"
      refute rendered =~ "zoom_client_secret"

      # The rest of the struct still renders — this is redaction, not opacity.
      assert rendered =~ "acct_1"
      assert rendered =~ "sub_1"
    end

    test "the secret stays out of a crash report's inspected GenServer state" do
      Application.put_env(:fermix_core, :meetings, rtms_credentials())

      # The shape Logger.Translator prints on a GenServer termination.
      state = %{config: Config.load(), phase: :streaming}

      refute inspect(state, limit: :infinity, printable_limit: :infinity) =~ "secret_1"
    end
  end

  defp rtms_credentials do
    [
      zoom_account_id: "acct_1",
      zoom_client_id: "client_1",
      zoom_client_secret: "secret_1",
      zoom_ws_subscription_id: "sub_1"
    ]
  end

  defp restore(key, nil), do: Application.delete_env(:fermix_core, key)
  defp restore(key, value), do: Application.put_env(:fermix_core, key, value)
end
