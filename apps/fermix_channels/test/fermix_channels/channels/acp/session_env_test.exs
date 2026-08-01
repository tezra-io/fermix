defmodule FermixChannels.Channels.Acp.SessionEnvTest do
  @moduledoc """
  The bridge env filter (M29 §4/§8.3): what survives the allowlist, what is
  discarded on arrival, and the custody posture — a struct that never prints its
  values.
  """

  use ExUnit.Case, async: true

  alias FermixChannels.Channels.Acp.SessionEnv

  describe "new/1 allowlist" do
    test "keeps exactly the named keys" do
      env =
        SessionEnv.new(%{
          "BUZZ_RELAY_URL" => "wss://relay.example",
          "BUZZ_PRIVATE_KEY" => "nsec1secret",
          "BUZZ_AUTH_TAG" => "tag-1",
          "BUZZ_ACP_DISPLAY_NAME" => "Fermix",
          "NOSTR_PRIVATE_KEY" => "nsec1other",
          "GIT_TERMINAL_PROMPT" => "0",
          "PATH" => "/opt/homebrew/bin:/usr/bin",
          "GIT_CONFIG_COUNT" => "2"
        })

      assert SessionEnv.to_map(env) == %{
               "BUZZ_RELAY_URL" => "wss://relay.example",
               "BUZZ_PRIVATE_KEY" => "nsec1secret",
               "BUZZ_AUTH_TAG" => "tag-1",
               "BUZZ_ACP_DISPLAY_NAME" => "Fermix",
               "NOSTR_PRIVATE_KEY" => "nsec1other",
               "GIT_TERMINAL_PROMPT" => "0",
               "PATH" => "/opt/homebrew/bin:/usr/bin",
               "GIT_CONFIG_COUNT" => "2"
             }
    end

    test "keeps every numbered GIT_CONFIG_KEY/VALUE pair" do
      env =
        SessionEnv.new(%{
          "GIT_CONFIG_KEY_0" => "credential.helper",
          "GIT_CONFIG_VALUE_0" => "buzz",
          "GIT_CONFIG_KEY_11" => "user.name",
          "GIT_CONFIG_VALUE_11" => "agent"
        })

      assert SessionEnv.keys(env) == [
               "GIT_CONFIG_KEY_0",
               "GIT_CONFIG_KEY_11",
               "GIT_CONFIG_VALUE_0",
               "GIT_CONFIG_VALUE_11"
             ]
    end

    test "discards everything else, including near-misses and non-string values" do
      env =
        SessionEnv.new(%{
          "OPENAI_API_KEY" => "sk-live",
          "HOME" => "/Users/operator",
          "AWS_SECRET_ACCESS_KEY" => "secret",
          "BUZZ_PRIVATE_KEY_BACKUP" => "nope",
          "GIT_CONFIG_KEY_" => "nope",
          "GIT_CONFIG_KEY_x" => "nope",
          "PATH_EXTRA" => "nope",
          "GIT_CONFIG_COUNT" => 2
        })

      assert SessionEnv.to_map(env) == %{}
    end

    test "an empty env is an empty overlay" do
      assert SessionEnv.to_map(SessionEnv.new(%{})) == %{}
      assert SessionEnv.keys(SessionEnv.new(%{})) == []
    end
  end

  describe "custody" do
    test "inspect names the keys and never the values" do
      env = SessionEnv.new(%{"BUZZ_PRIVATE_KEY" => "nsec1secret", "PATH" => "/usr/bin"})
      rendered = inspect(env)

      refute rendered =~ "nsec1secret"
      refute rendered =~ "/usr/bin"
      assert rendered =~ "BUZZ_PRIVATE_KEY"
      assert rendered =~ "redacted"
    end

    test "a struct nested in other state still redacts" do
      env = SessionEnv.new(%{"NOSTR_PRIVATE_KEY" => "nsec1nested"})
      refute inspect(%{sessions: %{"acp-1" => %{env: env}}}) =~ "nsec1nested"
    end
  end
end
