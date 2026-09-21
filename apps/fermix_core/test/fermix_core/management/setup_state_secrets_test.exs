defmodule FermixCore.Management.SetupStateSecretsTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.SetupState

  describe "the secrets row" do
    test "says where this home saves and whether it can save now" do
      report =
        SetupState.report(secret_store: fn -> :keyring end, secret_availability: fn -> :ready end)

      assert report["secrets"] == %{"store" => "keyring", "availability" => "ready"}
    end

    # The whole point of the two fields: a locked keyring still SAVES TO the
    # keyring. Collapsing that into one field would report "no store", which is
    # the untrue sentence this change exists to remove.
    test "a locked keyring is still the store this home saves to" do
      report =
        SetupState.report(
          secret_store: fn -> :keyring end,
          secret_availability: fn -> :locked end
        )

      assert report["secrets"] == %{"store" => "keyring", "availability" => "locked"}
    end

    test "a home on the file store can store whatever the keyring is doing" do
      report =
        SetupState.report(secret_store: fn -> :file end, secret_availability: fn -> :ready end)

      assert report["secrets"] == %{"store" => "file", "availability" => "ready"}
    end
  end
end
