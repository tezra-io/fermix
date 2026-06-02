defmodule FermixCore.Browser.PolicyTest do
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Config
  alias FermixCore.Browser.Policy

  setup do
    {:ok, config} = Config.current([])
    %{config: config}
  end

  test "allows public https and loopback", %{config: config} do
    assert {:ok, _uri} = Policy.validate_url("https://example.com", config)
    assert {:ok, _uri} = Policy.validate_url("http://localhost:4000", config)
    assert {:ok, _uri} = Policy.validate_url("http://127.0.0.1:4000", config)
    assert {:ok, _uri} = Policy.validate_url("about:blank", config)
  end

  test "blocks unsafe schemes", %{config: config} do
    for url <- [
          "file:///etc/passwd",
          "data:text/plain,hi",
          "javascript:alert(1)",
          "ftp://example.com"
        ] do
      assert {:error, error} = Policy.validate_url(url, config)
      assert error.code == "navigation_blocked"
    end
  end

  test "blocks private and metadata addresses by default", %{config: config} do
    for url <- [
          "http://10.0.0.1",
          "http://192.168.1.1",
          "http://172.16.0.1",
          "http://169.254.169.254"
        ] do
      assert {:error, error} = Policy.validate_url(url, config)
      assert error.code == "navigation_blocked"
    end
  end

  test "blocks IPv4-in-IPv6 representations of private/metadata hosts", %{config: config} do
    for url <- [
          # IPv4-mapped (::ffff:a.b.c.d)
          "http://[::ffff:169.254.169.254]",
          "http://[::ffff:10.0.0.1]",
          "http://[::ffff:192.168.0.1]",
          # IPv4-compatible (deprecated, ::a.b.c.d)
          "http://[::169.254.169.254]",
          "http://[::10.0.0.1]",
          "http://[::192.168.0.1]",
          # NAT64 (64:ff9b::a.b.c.d)
          "http://[64:ff9b::169.254.169.254]",
          "http://[64:ff9b::10.0.0.1]"
        ] do
      assert {:error, error} = Policy.validate_url(url, config)
      assert error.code == "navigation_blocked", "expected #{url} to be blocked"
    end
  end

  test "allows IPv4-mapped loopback but keeps genuine ::1 / :: intact", %{config: config} do
    assert {:ok, _uri} = Policy.validate_url("http://[::ffff:127.0.0.1]:4000", config)
    assert {:ok, _uri} = Policy.validate_url("http://[::1]:4000", config)
  end
end
