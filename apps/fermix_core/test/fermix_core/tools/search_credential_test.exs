defmodule FermixCore.Tools.SearchCredentialTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Tools.SearchCredential
  alias FermixCore.Tools.WebSearch.Backends.Brave

  @missing "auth_failed: missing Brave API key"

  setup do
    tools = Application.get_env(:fermix_core, :tools)
    on_exit(fn -> restore_tools(tools) end)
    :ok
  end

  describe "brave/1 — pure, over a caller-supplied config" do
    test "resolves the configured key" do
      assert {:ok, "brave-secret"} = SearchCredential.brave(brave_api_key: "brave-secret")
    end

    test "resolves from backend opts, which are the config plus the per-call context" do
      opts = [backend: :brave, brave_api_key: "brave-secret", context: %{agent_name: "test"}]

      assert {:ok, "brave-secret"} = SearchCredential.brave(opts)
    end

    test "an absent key is missing" do
      assert {:error, @missing} = SearchCredential.brave([])
      assert {:error, @missing} = SearchCredential.brave(backend: :brave)
    end

    test "an empty or whitespace-only key is missing, not a credential" do
      assert {:error, @missing} = SearchCredential.brave(brave_api_key: "")
      assert {:error, @missing} = SearchCredential.brave(brave_api_key: "   ")
      assert {:error, @missing} = SearchCredential.brave(brave_api_key: "\t\n ")
    end

    test "a surviving @keyring sentinel is missing — the secret never materialized" do
      assert {:error, @missing} = SearchCredential.brave(brave_api_key: "@keyring")
      assert {:error, @missing} = SearchCredential.brave(brave_api_key: "  @keyring  ")
    end

    test "a non-binary key is missing" do
      assert {:error, @missing} = SearchCredential.brave(brave_api_key: nil)
      assert {:error, @missing} = SearchCredential.brave(brave_api_key: 12_345)
      assert {:error, @missing} = SearchCredential.brave(brave_api_key: :brave)
    end

    test "a present key is returned exactly as configured — Setup.ConfigStore owns normalization" do
      assert {:ok, " brave-secret "} = SearchCredential.brave(brave_api_key: " brave-secret ")
    end

    test "refuses a config that is not a keyword list" do
      assert_raise FunctionClauseError, fn -> SearchCredential.brave(%{brave_api_key: "x"}) end
      assert_raise FunctionClauseError, fn -> SearchCredential.brave("brave-secret") end
    end
  end

  describe "brave/0 — the reader that performs the config I/O" do
    test "reads [fermix_core.tools.web_search].brave_api_key" do
      put_tools(web_search: [backend: :brave, brave_api_key: "brave-secret"])

      assert {:ok, "brave-secret"} = SearchCredential.brave()
    end

    test "the key resolves while another backend is selected — one key, many consumers" do
      put_tools(web_search: [backend: :duckduckgo, brave_api_key: "brave-secret"])

      assert {:ok, "brave-secret"} = SearchCredential.brave()
    end

    test "missing when the tools env holds no web_search section" do
      put_tools(web_fetch: [])

      assert {:error, @missing} = SearchCredential.brave()
    end

    test "missing when nothing at all is configured" do
      Application.delete_env(:fermix_core, :tools)

      assert {:error, @missing} = SearchCredential.brave()
    end
  end

  describe "redaction" do
    test "resolving a present key logs nothing and returns it only inside the success tuple" do
      secret = unique_secret()

      log =
        capture_log(fn ->
          assert {:ok, ^secret} = SearchCredential.brave(brave_api_key: secret)
        end)

      refute log =~ secret
    end

    test "the refusal is a constant that carries nothing derived from the rejected value" do
      for value <- ["", "   ", "@keyring", "  @keyring  ", nil] do
        assert {:error, message} = SearchCredential.brave(brave_api_key: value)
        assert message == @missing
        refute message =~ "keyring"
      end
    end

    test "a tools env the config loader never produces refuses without inspecting the key" do
      secret = unique_secret()

      # A raise here would render the whole section — including the key — into
      # an exception message and a stacktrace. Both malformed shapes must read
      # as unconfigured instead.
      for tools <- [
            %{web_search: [brave_api_key: secret]},
            [web_search: %{brave_api_key: secret}]
          ] do
        put_tools(tools)

        log = capture_log(fn -> assert {:error, @missing} = SearchCredential.brave() end)

        refute log =~ secret
      end
    end
  end

  describe "the Brave web-search backend resolves through the same seam" do
    test "configured?/1 answers exactly what the seam resolves" do
      assert Brave.configured?(brave_api_key: "brave-secret")
      refute Brave.configured?([])
      refute Brave.configured?(brave_api_key: "")
      refute Brave.configured?(brave_api_key: "   ")
      refute Brave.configured?(brave_api_key: "@keyring")
    end

    test "search/2 surfaces the seam's refusal before any HTTP request" do
      # No stub and no resolver are injected: reaching the transport would
      # leave this test dependent on the network, so a passing assertion is
      # itself the proof that the credential guard ran first.
      assert {:error, @missing, %{}} = Brave.search("fermix", [])
      assert {:error, @missing, %{}} = Brave.search("fermix", brave_api_key: "@keyring")
      assert {:error, @missing, %{}} = Brave.search("fermix", brave_api_key: "   ")
    end
  end

  defp unique_secret, do: "brave-must-not-leak-#{System.unique_integer([:positive])}"

  defp put_tools(tools), do: Application.put_env(:fermix_core, :tools, tools)

  defp restore_tools(nil), do: Application.delete_env(:fermix_core, :tools)
  defp restore_tools(value), do: Application.put_env(:fermix_core, :tools, value)
end
