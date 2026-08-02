defmodule FermixCore.Acp.IdentityTest do
  # Pure record construction: no filesystem, no env, no global state. The log
  # assertions key on this module's own prefix, so concurrent captures are safe.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixCore.Acp.Identity

  # Published NIP-19 vector (see nostr/key_test.exs for its derivation).
  @nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
  @secret_hex "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
  @public_hex "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"

  # A second identity, used as NOSTR_PRIVATE_KEY so the tests prove the id is
  # derived from BUZZ_PRIVATE_KEY and from nothing else.
  @nsec2 "nsec1n5kjpk2ulwe25uj4thrr8stmy0xe9hk7f0suw0sdeff34yfv2xkq2etz66"

  @operator_secret "sk-operator-must-never-be-carried"

  defp identity_keys do
    ~w(
      BUZZ_RELAY_URL BUZZ_PRIVATE_KEY BUZZ_AUTH_TAG BUZZ_ACP_DISPLAY_NAME
      NOSTR_PRIVATE_KEY GIT_TERMINAL_PROMPT GIT_CONFIG_COUNT
      GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1
      PATH
    )
  end

  defp hello_env(overrides \\ %{}) do
    %{
      # kept — the §4 allowlist
      "BUZZ_RELAY_URL" => "wss://relay.example.test",
      "BUZZ_PRIVATE_KEY" => @nsec,
      "BUZZ_AUTH_TAG" => "tag-abc123",
      "BUZZ_ACP_DISPLAY_NAME" => "Fermix",
      "NOSTR_PRIVATE_KEY" => @nsec2,
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_CONFIG_COUNT" => "2",
      "GIT_CONFIG_KEY_0" => "credential.helper",
      "GIT_CONFIG_VALUE_0" => "!buzz git-credential",
      "GIT_CONFIG_KEY_1" => "user.name",
      "GIT_CONFIG_VALUE_1" => "Fermix",
      "PATH" => "/opt/buzz/bin:/usr/bin",
      # dropped — the operator's own world
      "OPENAI_API_KEY" => @operator_secret,
      "AWS_SECRET_ACCESS_KEY" => "aws-secret",
      "HOME" => "/Users/operator",
      "TERM" => "xterm-256color",
      # dropped — GIT_CONFIG pairs must be numbered
      "GIT_CONFIG_KEY_x" => "not-numbered",
      "GIT_CONFIG_VALUE_" => "not-numbered",
      "GIT_CONFIG_KEY_1x" => "not-numbered"
    }
    |> Map.merge(overrides)
  end

  describe "new/1 — the allowlist" do
    test "keeps exactly the allowlist and drops everything else" do
      env = hello_env() |> Identity.new() |> Identity.to_env()

      assert Map.keys(env) |> Enum.sort() == Enum.sort(identity_keys())
    end

    test "carries the numbered GIT_CONFIG pairs and drops unnumbered lookalikes" do
      identity = Identity.new(hello_env())

      assert identity.git_config == %{
               "GIT_TERMINAL_PROMPT" => "0",
               "GIT_CONFIG_COUNT" => "2",
               "GIT_CONFIG_KEY_0" => "credential.helper",
               "GIT_CONFIG_VALUE_0" => "!buzz git-credential",
               "GIT_CONFIG_KEY_1" => "user.name",
               "GIT_CONFIG_VALUE_1" => "Fermix"
             }
    end

    test "drops entries whose key or value is not a string" do
      env = hello_env(%{"BUZZ_AUTH_TAG" => 42}) |> Map.put(:path, "/atom/key")

      identity = Identity.new(env)

      assert identity.auth_tag == nil
      refute Map.has_key?(Identity.to_env(identity), "BUZZ_AUTH_TAG")
    end

    # Carried over from the deleted `Acp.SessionEnvTest`: a client that presents
    # no env at all (the hello's `env` key is optional) is an empty overlay, not
    # a crash and not a record.
    test "an empty env is an empty overlay" do
      identity = Identity.new(%{})

      assert identity.id == nil
      assert Identity.to_env(identity) == %{}
      assert Identity.env_keys(identity) == []
    end

    test "the operator's own secrets never reach the record" do
      identity = Identity.new(hello_env())
      rendered = inspect(identity.secrets) <> inspect(Identity.to_env(identity))

      refute rendered =~ @operator_secret
      refute rendered =~ "aws-secret"
    end
  end

  describe "new/1 — identity derivation" do
    test "derives the id from BUZZ_PRIVATE_KEY, not from NOSTR_PRIVATE_KEY" do
      identity = Identity.new(hello_env())

      assert identity.id == @public_hex
      assert identity.kind == :buzz
    end

    test "the hex and nsec forms of one key produce the same id" do
      hex = Identity.new(hello_env(%{"BUZZ_PRIVATE_KEY" => @secret_hex}))

      assert hex.id == Identity.new(hello_env()).id
    end

    test "fills the record fields from the presented env" do
      identity = Identity.new(hello_env())

      assert identity.display_name == "Fermix"
      assert identity.relay_url == "wss://relay.example.test"
      assert identity.auth_tag == "tag-abc123"
      assert identity.path == "/opt/buzz/bin:/usr/bin"
      assert identity.secrets == %{"BUZZ_PRIVATE_KEY" => @nsec, "NOSTR_PRIVATE_KEY" => @nsec2}
    end

    test "stamps first_seen and last_seen" do
      identity = Identity.new(hello_env())

      assert %DateTime{} = identity.first_seen
      assert identity.first_seen == identity.last_seen
    end
  end

  describe "new/1 — the drop rule (§17.2)" do
    test "a malformed nsec yields no id, no secrets, and no posting capability" do
      env = hello_env(%{"BUZZ_PRIVATE_KEY" => "nsec1thisisnotarealkey"})

      _log = capture_log(fn -> send(self(), Identity.new(env)) end)
      identity = receive_identity()

      assert identity.id == nil
      assert identity.secrets == %{}
      refute Map.has_key?(Identity.to_env(identity), "BUZZ_PRIVATE_KEY")
      refute Map.has_key?(Identity.to_env(identity), "NOSTR_PRIVATE_KEY")
      refute Identity.posting_capable?(Identity.to_env(identity))
    end

    test "a malformed nsec is named in one warning that never prints the key" do
      env = hello_env(%{"BUZZ_PRIVATE_KEY" => "nsec1thisisnotarealkey"})

      log = capture_log(fn -> Identity.new(env) end)
      lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "Acp.Identity"))

      assert length(lines) == 1
      assert log =~ "BUZZ_PRIVATE_KEY"
      refute log =~ "nsec1thisisnotarealkey"
    end

    test "an absent key is the ordinary identity-less case and logs nothing" do
      env = hello_env() |> Map.delete("BUZZ_PRIVATE_KEY")

      log = capture_log(fn -> send(self(), Identity.new(env)) end)
      identity = receive_identity()

      refute log =~ "Acp.Identity"
      assert identity.id == nil
      assert identity.secrets == %{}
    end

    test "the ambient record keeps the non-secret allowlist (§17.5)" do
      env = hello_env() |> Map.delete("BUZZ_PRIVATE_KEY")
      ambient = env |> Identity.new() |> Identity.to_env()

      assert Map.keys(ambient) |> Enum.sort() ==
               identity_keys()
               |> Kernel.--(["BUZZ_PRIVATE_KEY", "NOSTR_PRIVATE_KEY"])
               |> Enum.sort()

      assert ambient["PATH"] == "/opt/buzz/bin:/usr/bin"
    end
  end

  describe "to_env/1" do
    test "round-trips a durable record to exactly the filtered hello env" do
      env = hello_env()

      assert env |> Identity.new() |> Identity.to_env() == Map.take(env, identity_keys())
    end

    test "regenerates the shape from the fields, not from a retained copy" do
      identity = %{Identity.new(hello_env()) | relay_url: "wss://moved.example.test"}

      assert Identity.to_env(identity)["BUZZ_RELAY_URL"] == "wss://moved.example.test"
    end

    test "omits fields the client never presented" do
      env = hello_env() |> Map.delete("BUZZ_AUTH_TAG") |> Map.delete("BUZZ_ACP_DISPLAY_NAME")
      rebuilt = env |> Identity.new() |> Identity.to_env()

      refute Map.has_key?(rebuilt, "BUZZ_AUTH_TAG")
      refute Map.has_key?(rebuilt, "BUZZ_ACP_DISPLAY_NAME")
    end
  end

  describe "posting_capable?/1" do
    test "true only when the env carries a non-empty signing key and a PATH" do
      env = hello_env() |> Identity.new() |> Identity.to_env()

      assert Identity.posting_capable?(env)
      refute Identity.posting_capable?(Map.delete(env, "PATH"))
      refute Identity.posting_capable?(Map.delete(env, "BUZZ_PRIVATE_KEY"))
      refute Identity.posting_capable?(Map.put(env, "BUZZ_PRIVATE_KEY", ""))
      refute Identity.posting_capable?(%{})
      refute Identity.posting_capable?(nil)
    end
  end

  describe "id_from_env/1" do
    test "agrees with new/1 on the same env" do
      assert Identity.id_from_env(hello_env()) == {:ok, @public_hex}
      assert {:ok, id} = Identity.id_from_env(hello_env())
      assert Identity.new(hello_env()).id == id
    end

    test "names the two failure kinds distinctly" do
      assert {:error, {:missing, "BUZZ_PRIVATE_KEY"}} =
               Identity.id_from_env(Map.delete(hello_env(), "BUZZ_PRIVATE_KEY"))

      assert {:error, {:invalid_nsec, _detail}} =
               Identity.id_from_env(%{"BUZZ_PRIVATE_KEY" => "nsec1thisisnotarealkey"})
    end

    test "an empty key is missing, not malformed" do
      assert {:error, {:missing, "BUZZ_PRIVATE_KEY"}} =
               Identity.id_from_env(%{"BUZZ_PRIVATE_KEY" => ""})
    end
  end

  describe "Inspect" do
    test "prints key names and never a value, however nested" do
      identity = Identity.new(hello_env())

      for rendered <- [
            inspect(identity),
            inspect(%{connection: %{identity: identity}}),
            inspect([{:peer, [identity]}])
          ] do
        assert rendered =~ "Acp.Identity"
        assert rendered =~ "BUZZ_PRIVATE_KEY"
        assert rendered =~ "redacted"
        refute rendered =~ @nsec
        refute rendered =~ @nsec2
        refute rendered =~ "tag-abc123"
        refute rendered =~ "/opt/buzz/bin"
        refute rendered =~ "!buzz git-credential"
      end
    end

    test "still renders the identity-less record" do
      identity = Identity.new(Map.delete(hello_env(), "BUZZ_PRIVATE_KEY"))

      assert inspect(identity) =~ "Acp.Identity"
      refute inspect(identity) =~ @nsec2
    end
  end

  defp receive_identity do
    receive do
      %Identity{} = identity -> identity
    after
      0 -> flunk("Identity.new/1 did not return a record")
    end
  end
end
