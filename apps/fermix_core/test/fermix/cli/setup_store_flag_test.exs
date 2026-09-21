defmodule Fermix.CLI.SetupStoreFlagTest do
  use ExUnit.Case, async: true

  alias Fermix.CLI.Setup

  describe "--store" do
    test "file records the consent before any answer is written" do
      owner = self()

      run(["--store", "file", "--print-state"], fn store ->
        send(owner, {:recorded, store})
        :ok
      end)

      assert_received {:recorded, :file}
    end

    test "keyring records the return to the default" do
      owner = self()

      run(["--store", "keyring", "--print-state"], fn store ->
        send(owner, {:recorded, store})
        :ok
      end)

      assert_received {:recorded, :keyring}
    end

    # Running setup is not a decision about where secrets live, so a run that
    # does not name a store leaves the home's own choice alone.
    test "an absent flag records nothing" do
      run(["--print-state"], fn _store -> flunk("recorded a choice nobody made") end)
    end

    test "a store this engine does not implement is refused" do
      code = run(["--store", "kwallet", "--print-state"], fn _store -> :ok end)

      assert code != 0
    end
  end

  defp run(argv, recorder) do
    Setup.run(argv,
      put_secret_store: recorder,
      build_info: FermixCore.BuildInfo,
      standalone?: fn -> false end,
      display?: fn -> false end,
      setup_ready?: fn -> true end,
      home_owner: Fermix.CLI.SetupStoreFlagTest.NoApp,
      puts: fn _line -> :ok end
    )
  end

  defmodule NoApp do
    def app_managed?(_opts), do: false
  end
end
