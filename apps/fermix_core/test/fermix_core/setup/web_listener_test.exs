defmodule FermixCore.Setup.WebListenerTest do
  @moduledoc """
  The one listener-port resolver (M38 §4.7).

  Every case names the distribution and hands the resolver an environment map,
  so both configurations are reachable from a macOS test run and neither answer
  depends on the host this suite happens to execute on.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Setup.WebListener

  describe "a packaged engine" do
    test "takes the port from the settings file" do
      assert WebListener.port("linux_package", %{}, configured: 4555) ==
               {:ok, %{port: 4555, source: :config}}
    end

    test "falls to the default when nothing is configured" do
      assert WebListener.port("linux_package", %{}, configured: nil) ==
               {:ok, %{port: 4030, source: :default}}
    end

    # One unit file serves every account and carries no per-account values, so a
    # shell variable that quietly moved the listener would leave a daemon
    # answering where nothing else can predict. The refusal names the setting
    # that works while the daemon is down.
    test "refuses a PORT override and names the persisted remedy" do
      assert {:error, {:port_not_used, sentence}} =
               WebListener.port("linux_package", %{"PORT" => "4040"}, configured: 4555)

      assert sentence =~ "PORT is not used by the packaged engine"
      assert sentence =~ "fermix service install --port N"
    end

    # The refusal is about a supplied value, not about the variable existing in
    # some shape: an empty PORT is how a shell spells "unset".
    test "an empty PORT is not an override" do
      assert WebListener.port("linux_package", %{"PORT" => ""}, configured: 4555) ==
               {:ok, %{port: 4555, source: :config}}
    end
  end

  describe "a standalone or source engine" do
    test "keeps PORT, exactly as it always has" do
      assert WebListener.port("standalone", %{"PORT" => "4545"}, configured: 4555) ==
               {:ok, %{port: 4545, source: :environment}}
    end

    test "falls to the persisted setting when PORT is unset" do
      assert WebListener.port("standalone", %{}, configured: 4555) ==
               {:ok, %{port: 4555, source: :config}}
    end

    test "falls to the default when neither is set" do
      assert WebListener.port("standalone", %{}, configured: nil) ==
               {:ok, %{port: 4030, source: :default}}
    end

    # A privileged port through PORT still works: narrowing it to the settings
    # file's 1024 floor would refuse an install that runs today.
    test "PORT keeps its historical range" do
      assert WebListener.port("standalone", %{"PORT" => "80"}, configured: nil) ==
               {:ok, %{port: 80, source: :environment}}
    end

    test "a PORT that is not a port number is named, not rounded away" do
      assert WebListener.port("standalone", %{"PORT" => "70000"}, configured: nil) ==
               {:error, {:invalid_port, :environment, "70000"}}

      assert WebListener.port("standalone", %{"PORT" => "http"}, configured: nil) ==
               {:error, {:invalid_port, :environment, "http"}}
    end

    test "a PORT of some other shape entirely is refused rather than defaulted" do
      assert WebListener.port("standalone", %{"PORT" => 4545}, configured: nil) ==
               {:error, {:invalid_port, :environment, 4545}}
    end
  end

  describe "the persisted setting's bounds" do
    test "1024 through 65535 inclusive" do
      assert WebListener.configured_bounds() == 1024..65_535
      assert WebListener.valid_configured_port?(1024)
      assert WebListener.valid_configured_port?(65_535)
      refute WebListener.valid_configured_port?(1023)
      refute WebListener.valid_configured_port?(65_536)
      refute WebListener.valid_configured_port?("4030")
      refute WebListener.valid_configured_port?(nil)
    end

    test "the refusal sentence names both ends and the offending value" do
      sentence = WebListener.invalid_port_sentence(80)

      assert sentence =~ "1024"
      assert sentence =~ "65535"
      assert sentence =~ "80"
    end
  end

  # The default lives in one place, and `FermixCore.Setup.Endpoint` reads it
  # through this resolver rather than keeping a second copy.
  test "the default port is 4030" do
    assert WebListener.default_port() == 4030
  end
end
