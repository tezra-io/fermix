defmodule FermixCore.Home.Snapshot.RecoveryTest do
  # Always On setup §4: the recovery passphrase typed at Move now is checked
  # against the key a primary keeps, or becomes that key when none is kept, so
  # a move never makes a second key for an unchanged passphrase.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Recovery

  @passphrase "invented-harbor-juniper-lantern"
  @salt :binary.copy(<<7>>, 16)

  # PBKDF2 at 600,000 rounds is the slow part, so the kept key is derived once.
  setup_all do
    {:ok, pair} = Recipient.derive(@passphrase, @salt)
    %{kept: Recipient.public(pair)}
  end

  defp saving(test) do
    fn recipient ->
      send(test, {:saved, recipient})
      {:ok, %{}}
    end
  end

  defp kept_config(kept), do: [recipient: Recipient.encode(kept)]

  describe "verify_or_set/2 with a key kept" do
    test "the passphrase that made it answers that key and saves nothing", %{kept: kept} do
      opts = [config: kept_config(kept), save_recipient: saving(self())]

      assert Recovery.verify_or_set(@passphrase, opts) == {:ok, kept}
      refute_received {:saved, _recipient}
    end

    test "another passphrase is not the one set, and saves nothing", %{kept: kept} do
      opts = [config: kept_config(kept), save_recipient: saving(self())]

      assert Recovery.verify_or_set("invented-orchard-meridian", opts) ==
               {:error, :wrong_passphrase}

      assert Recovery.error_sentence(:wrong_passphrase) ==
               "That is not the recovery passphrase you set."

      refute_received {:saved, _recipient}
    end
  end

  describe "verify_or_set/2 with no key kept" do
    test "derives a new key, keeps its public half and answers it" do
      opts = [config: [], save_recipient: saving(self())]

      assert {:ok, recipient} = Recovery.verify_or_set(@passphrase, opts)
      assert_received {:saved, ^recipient}
      refute Map.has_key?(recipient, :secret_key)

      # The key it kept is the one the passphrase and its salt derive.
      {:ok, again} = Recipient.derive(@passphrase, recipient.salt)
      assert Recipient.matches?(again, recipient)
    end

    test "a kept key that cannot be read is said, and nothing replaces it" do
      opts = [config: [recipient: "fxsnap1.not-a-key"], save_recipient: saving(self())]

      assert Recovery.verify_or_set(@passphrase, opts) == {:error, :key_unreadable}
      refute_received {:saved, _recipient}
    end

    test "a key that could not be kept is said, and nothing is answered" do
      opts = [config: [], save_recipient: fn _recipient -> {:error, :eacces} end]

      assert Recovery.verify_or_set(@passphrase, opts) == {:error, {:not_saved, :eacces}}
    end
  end

  describe "set/2" do
    test "replaces the kept key with a new one under a new salt", %{kept: kept} do
      opts = [config: kept_config(kept), save_recipient: saving(self())]

      assert {:ok, recipient} = Recovery.set(@passphrase, opts)
      assert_received {:saved, ^recipient}
      refute recipient.salt == kept.salt
    end
  end

  test "a passphrase outside its bounds is refused before anything is read or saved", %{
    kept: kept
  } do
    opts = [config: kept_config(kept), save_recipient: saving(self())]

    for {passphrase, reason} <- [
          {"eleven-byte", :passphrase_too_short},
          {String.duplicate("a", 1_025), :passphrase_not_text},
          {42, :passphrase_not_text}
        ],
        check <- [&Recovery.verify_or_set/2, &Recovery.set/2] do
      assert check.(passphrase, opts) == {:error, reason}
    end

    assert Recovery.error_sentence(:passphrase_too_short) ==
             "The recovery passphrase must be at least 12 bytes long."

    assert Recovery.error_sentence(:passphrase_not_text) ==
             "The recovery passphrase is text of at most 1024 bytes."

    refute_received {:saved, _recipient}
  end

  test "no answer or refusal carries the passphrase", %{kept: kept} do
    for config <- [kept_config(kept), []] do
      opts = [config: config, save_recipient: fn _recipient -> {:ok, %{}} end]

      for passphrase <- [@passphrase, "invented-orchard-meridian"] do
        refute inspect(Recovery.verify_or_set(passphrase, opts)) =~ passphrase
      end
    end
  end
end
