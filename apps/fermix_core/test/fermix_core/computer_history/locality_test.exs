defmodule FermixCore.ComputerHistory.LocalityTest do
  @moduledoc "MILESTONE_32 §9.3 — the strict loopback classifier."
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.Locality

  test "loopback hosts are local" do
    assert Locality.loopback?("http://localhost:11434/v1")
    assert Locality.loopback?("http://127.0.0.1:11434/v1")
    assert Locality.loopback?("http://127.5.6.7:11434/v1")
    assert Locality.loopback?("https://LOCALHOST/v1")
    assert Locality.loopback?("http://[::1]:11434/v1")
  end

  test "private-LAN, public, and unverifiable hosts are remote" do
    # A private-LAN address can name another host — NOT loopback.
    refute Locality.loopback?("http://192.168.1.10:11434/v1")
    refute Locality.loopback?("http://10.0.0.5:11434/v1")
    refute Locality.loopback?("https://api.anthropic.com/v1")
    refute Locality.loopback?("https://ollama.example.com/v1")
  end

  test "nil, non-binary, and malformed URLs fail closed to remote" do
    refute Locality.loopback?(nil)
    refute Locality.loopback?(:ollama)
    refute Locality.loopback?("")
    refute Locality.loopback?("not a url")
  end
end
