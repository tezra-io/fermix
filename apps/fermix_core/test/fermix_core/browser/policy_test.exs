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

  test "allows IPv4-mapped loopback but keeps genuine ::1 intact", %{config: config} do
    assert {:ok, _uri} = Policy.validate_url("http://[::ffff:127.0.0.1]:4000", config)
    assert {:ok, _uri} = Policy.validate_url("http://[::1]:4000", config)
  end

  # The whole classifier in one table, blocks and deliberate allows together, so
  # the two halves cannot drift apart: every literal form the IPv4-in-IPv6 folder
  # can produce, every private range, the DNS-free hostname suffixes, and the
  # root-anchored spelling of all of them. The allows are as load-bearing as the
  # blocks — reaching your own dev server is the point of a browser tool on your
  # own machine.
  #
  # Note which rule answers which form. An address literal — compressed or
  # dotted — is answered by `private_ip?/1`; only a name reaches the suffix and
  # single-label rules. Both IPv6 spellings of the same address are in the table
  # on purpose: they must agree instead of contradicting each other.
  #
  # A trailing dot is the DNS root anchor, so `host.` and `host` are the same
  # host and Chrome reaches both — it drops the empty final label. Every answer
  # above therefore repeats below with the anchor appended, because the anchored
  # spelling is the one an attacker types.
  @classifier_cases [
    # The headline bypass: :: is a loopback alias on every stack that accepts it.
    {"http://[::]:11434", :blocked, "unspecified IPv6 reaches loopback services"},
    {"http://[::0.0.0.0]:11434", :blocked, "same address, dotted spelling, classifier path"},
    {"http://[::1]:4000", :allowed, "genuine IPv6 loopback — deliberate allow"},
    {"http://[::ffff:127.0.0.1]:4000", :allowed, "IPv4-mapped loopback folds to 127.0.0.1"},
    {"http://[::127.0.0.1]:4000", :allowed, "IPv4-compatible loopback folds to 127.0.0.1"},
    {"http://[64:ff9b::127.0.0.1]:4000", :allowed, "NAT64 loopback folds to 127.0.0.1"},
    {"http://[64:ff9b::7f00:1]:4000", :allowed, "same NAT64 loopback, compressed spelling"},
    {"http://[64:ff9b::169.254.169.254]", :blocked, "NAT64 metadata folds to 169.254.169.254"},
    {"http://[64:ff9b::a9fe:a9fe]", :blocked, "same NAT64 metadata, compressed spelling"},
    {"http://[fc00::]", :blocked, "unique local address fc00::/7"},
    {"http://[fe80::]", :blocked, "link-local fe80::/10"},
    {"http://[fe80::1.2.3.4]", :blocked, "link-local, dotted spelling, classifier path"},
    {"http://[fec0::]", :blocked, "deprecated site-local fec0::/10"},
    {"http://[fec0::1.2.3.4]", :blocked, "site-local, dotted spelling, classifier path"},
    {"http://169.254.169.254", :blocked, "cloud metadata"},
    {"http://0.0.0.0", :blocked, "IPv4 unspecified"},
    {"http://10.0.0.1", :blocked, "private 10/8"},
    {"http://172.16.0.1", :blocked, "private 172.16/12"},
    {"http://192.168.1.1", :blocked, "private 192.168/16"},
    {"http://127.0.0.1:4000", :allowed, "IPv4 loopback — deliberate allow"},
    # Suffix blocks: no DNS, and metadata.google.internal dies outright.
    {"http://metadata.google.internal", :blocked, ".internal suffix"},
    {"http://printer.local", :blocked, ".local suffix"},
    {"http://app.localhost", :blocked, ".localhost suffix"},
    {"http://printer", :blocked, "single-label name, no DNS to consult"},
    {"http://localhost:4000", :allowed, "localhost — deliberate allow"},
    {"https://example.com", :allowed, "public host stays reachable"},
    # A literal is judged as an address, so the two families answer alike. A
    # public IPv6 literal carries no dot and used to be refused as a single-label
    # name while its IPv4 equivalent was waved through; that split is gone.
    {"http://1.1.1.1", :allowed, "public IPv4 literal"},
    {"http://[2606:4700::1]", :allowed, "public IPv6 literal — same answer"},
    # Same classifier, every host root-anchored.
    {"http://metadata.google.internal./", :blocked, "root-anchored .internal"},
    {"http://metadata.google.internal../", :blocked, "repeated root anchor"},
    {"http://printer.local./", :blocked, "root-anchored .local"},
    {"http://app.localhost./", :blocked, "root-anchored .localhost"},
    {"http://printer./", :blocked, "root-anchored single-label name"},
    {"http://169.254.169.254./", :blocked, "root-anchored metadata literal"},
    {"http://0.0.0.0./", :blocked, "root-anchored IPv4 unspecified"},
    {"http://10.0.0.1./", :blocked, "root-anchored private 10/8"},
    {"http://172.16.0.1./", :blocked, "root-anchored private 172.16/12"},
    {"http://192.168.1.1./", :blocked, "root-anchored private 192.168/16"},
    {"http://[::0.0.0.0.]:11434", :blocked, "root anchor inside an unspecified literal"},
    {"http://[::ffff:169.254.169.254.]", :blocked, "root anchor inside a folded literal"},
    {"http://localhost./", :allowed, "root-anchored localhost stays allowed"},
    {"http://127.0.0.1.:4000", :allowed, "root-anchored IPv4 loopback stays allowed"},
    {"http://[::1.]:4000", :allowed, "root-anchored IPv6 loopback stays allowed"},
    {"http://[::ffff:127.0.0.1.]:4000", :allowed, "root anchor inside a folded loopback"},
    {"https://example.com./", :allowed, "root-anchored public host stays reachable"}
  ]

  test "private-address classifier answers every form the same way, every time" do
    # Establish the shipped posture in this test rather than inheriting it: the
    # table only means something against allow_private_network: false.
    {:ok, config} = Config.current(allow_private_network: false)

    for {url, expected, why} <- @classifier_cases do
      actual =
        case Policy.validate_url(url, config) do
          {:ok, _uri} -> :allowed
          {:error, %{code: "navigation_blocked"}} -> :blocked
        end

      assert actual == expected, "#{url} should be #{expected} (#{why}), got #{actual}"
    end
  end

  test "allowed_hosts still wins over the suffix blocks" do
    {:ok, config} = Config.current(allow_private_network: false, allowed_hosts: ["nas.local"])

    assert {:ok, _uri} = Policy.validate_url("http://nas.local", config)
    assert {:ok, _uri} = Policy.validate_url("http://nas.local./", config)
    assert {:error, _error} = Policy.validate_url("http://other.local", config)
    assert {:error, _error} = Policy.validate_url("http://other.local./", config)
  end

  # Both sides of the membership test are canonicalized by the same function, so
  # an operator's entry means one host however they spelled it.
  test "an allowed_hosts entry matches whatever case and anchor the URL uses" do
    {:ok, config} = Config.current(allow_private_network: false, allowed_hosts: ["NAS.local."])

    assert {:ok, _uri} = Policy.validate_url("http://nas.local", config)
    assert {:ok, _uri} = Policy.validate_url("http://NAS.LOCAL./", config)
  end

  # A host of nothing but root anchors normalizes to the empty string. That is
  # not a name and not a literal, so it is refused rather than waved through as
  # an unrecognized public host.
  test "a bare root anchor is not a host" do
    {:ok, config} = Config.current(allow_private_network: false)

    for url <- ["http://./", "http://../"] do
      assert {:error, error} = Policy.validate_url(url, config)
      assert error.code == "navigation_blocked", "expected #{url} to be blocked"
      assert error.message == "URL must include a host"
    end
  end

  # An operator who narrows allowed_hosts is tightening which *names* they trust,
  # not giving up half of loopback: `::1` and `127.0.0.1` are address literals and
  # must answer alike once the shipped defaults are gone.
  test "both loopbacks survive an operator-set allowed_hosts" do
    {:ok, config} = Config.current(allow_private_network: false, allowed_hosts: ["example.org"])

    assert {:ok, _uri} = Policy.validate_url("http://127.0.0.1:4000", config)
    assert {:ok, _uri} = Policy.validate_url("http://[::1]:4000", config)
    assert {:error, _error} = Policy.validate_url("http://[::]:11434", config)
    assert {:error, _error} = Policy.validate_url("http://192.168.1.1", config)
    assert {:error, _error} = Policy.validate_url("http://printer", config)
  end
end
