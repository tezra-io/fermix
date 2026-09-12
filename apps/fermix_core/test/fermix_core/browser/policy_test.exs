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
      # The refusal names its recovery inline: the model is its primary reader.
      assert error.message =~ "allowed_hosts"
      assert error.message =~ "[fermix_core.browser]"
    end
  end

  test "an internal-hostname refusal names the allowed_hosts recovery", %{config: config} do
    assert {:error, error} = Policy.validate_url("http://metadata.google.internal", config)
    assert error.message =~ "allowed_hosts"
    assert error.message =~ "[fermix_core.browser]"
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
    # The inet_aton spellings Chrome also resolves: `:inet.parse_address/1` is
    # deliberately lenient, so every one of these IS the metadata literal and
    # must answer as one. These rows pin that leniency — a refactor to
    # `parse_strict_address/1` (the right call for `mobile.bind`) would turn
    # each into an allowed dotted NAME here, and that regression must fail loud.
    {"http://0xa9.0xfe.0xa9.0xfe", :blocked, "hex-octet spelling of the metadata literal"},
    {"http://0251.0376.0251.0376", :blocked, "octal-octet spelling of the metadata literal"},
    {"http://169.254.43518", :blocked, "three-part inet_aton spelling of the metadata literal"},
    {"http://2852039166", :blocked, "dword spelling of the metadata literal"},
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
    # A bracketed IPv6 authority is answered by `:inet.parse_address/1` alone, and
    # it rejects a trailing dot — so does Chrome, which will not fetch this URL at
    # all. Trimming the anchor first would mean vetting a spelling no browser
    # accepts, which is the whole failure mode the canonical rule exists to stop.
    {"http://[::1.]:4000", :blocked, "an IPv6 literal is not root-anchorable"},
    {"http://[::ffff:127.0.0.1.]:4000", :blocked, "same, inside a folded loopback"},
    {"https://example.com./", :allowed, "root-anchored public host stays reachable"},
    # The canonical-alphabet family. Every blocked spelling below names a
    # DIFFERENT machine in Chrome than the one `URI.parse/1` hands this module —
    # `%69` decodes to `i`, UTS-46 folds the three Unicode full stops and DELETES
    # soft hyphen, and `\` ends the authority for a special scheme — so none of
    # them can be vetted here at all and all are refused unvetted.
    {"http://metadata.google.%69nternal/", :blocked,
     "percent-escaped label decodes to .internal"},
    {"http://metadata%2egoogle%2einternal/", :blocked, "percent-escaped label separators"},
    {"http://192.168.1.1%2e/", :blocked, "percent-escaped anchor on a private literal"},
    {"http://169.254.169.254%2E/", :blocked, "same escape, uppercase, metadata literal"},
    {"http://169.254.169.254\\.example.com/", :blocked, "backslash ends the authority in Chrome"},
    # The same backslash one component earlier. `URI.parse/1` splits userinfo at
    # the last `@`, so the private host lands in `userinfo` and the URL's `host`
    # is an innocent public name — a host-only alphabet check never sees these.
    # Chrome ends the authority at the backslash and fetches the private host.
    {"http://169.254.169.254\\@example.com/", :blocked, "metadata literal hidden in userinfo"},
    {"http://metadata.google.internal\\@example.com/", :blocked, "same, spelled as a name"},
    {"https://169.254.169.254\\@example.com/", :blocked, "same under https"},
    {"http://169.254.169.254:80\\@example.com/", :blocked, "same, past an explicit port"},
    {"http://192.168.1.1\\@example.com/latest/", :blocked, "same, private literal"},
    # The authority rule refuses an ambiguous authority, not credentials: an `@`
    # both parsers read the same way still names the host after it.
    {"http://user:pass@example.com/", :allowed, "ordinary userinfo names no second host"},
    {"http://metadata.google．internal/", :blocked, "U+FF0E fullwidth full stop"},
    {"http://169.254.169.254。/", :blocked, "U+3002 ideographic full stop"},
    {"http://192.168.1.1｡/", :blocked, "U+FF61 halfwidth ideographic full stop"},
    {"http://metadata.google.inter­nal/", :blocked, "soft hyphen, deleted by UTS-46"},
    {"http://%FF.example.com/", :blocked, "percent-escaped invalid UTF-8"},
    {"http://exa mple.com/", :blocked, "raw space"},
    {"http://exa\tmple.com/", :blocked, "raw tab"},
    {"http://münchen.de/", :blocked, "Unicode IDN — punycode is the spelling that works"},
    {"https://xn--mnchen-3ya.de/", :allowed, "the punycode spelling of that same IDN"},
    {"https://XN--MNCHEN-3YA.DE/", :allowed, "punycode is case-insensitive"},
    {"http://a_b.com/", :allowed, "underscore is verbatim in Chrome — it aliases nothing"}
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

  # A host of nothing but root anchors canonicalizes to the empty string. That is
  # not a name and not a literal, so it is refused rather than waved through as
  # an unrecognized public host — and it is refused as the unvettable SPELLING it
  # is, which is the reason a reader can act on.
  test "a bare root anchor is not a host" do
    {:ok, config} = Config.current(allow_private_network: false)

    for url <- ["http://./", "http://../"] do
      assert {:error, error} = Policy.validate_url(url, config)
      assert error.code == "navigation_blocked", "expected #{url} to be blocked"
      assert error.details["reason"] == "non_canonical_host"
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

  # ── the canonical host alphabet ────────────────────────────────────────────

  # The alphabet is the whole rule, so it is tested as the whole rule rather than
  # case by case: EVERY byte outside it must refuse. Enumerating the complement
  # is what keeps this closed under bypass families nobody has thought of —
  # widening the alphabet without thinking fails here, and a new spelling that
  # uses an already-refused byte cannot be "forgotten", because the byte is
  # already in the loop.
  @canonical_alphabet ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"

  test "every byte outside the canonical alphabet refuses the host that carries it" do
    for byte <- 0..255, byte not in @canonical_alphabet do
      host = "example" <> <<byte>> <> ".com"

      assert Policy.canonical_host(host) == :error,
             "byte #{byte} must not be vettable inside a host"
    end
  end

  test "the canonical alphabet accepts exactly the spellings Chrome preserves verbatim" do
    assert Policy.canonical_host("Example.COM") == {:ok, "example.com"}
    assert Policy.canonical_host("example.com.") == {:ok, "example.com"}
    assert Policy.canonical_host("a_b-c.example") == {:ok, "a_b-c.example"}
    assert Policy.canonical_host("XN--MNCHEN-3YA.DE") == {:ok, "xn--mnchen-3ya.de"}
    assert Policy.canonical_host("127.0.0.1") == {:ok, "127.0.0.1"}
    assert Policy.canonical_host("::1") == {:ok, "::1"}
    assert Policy.canonical_host("::FFFF:127.0.0.1") == {:ok, "::ffff:127.0.0.1"}
    assert Policy.canonical_host(".") == :error
    assert Policy.canonical_host("") == :error
    assert Policy.canonical_host("::1.") == :error
    assert Policy.canonical_host("münchen.de") == :error
  end

  test "a non-canonical host names its own fix" do
    {:ok, config} = Config.current([])

    assert {:error, error} = Policy.validate_url("http://münchen.de/", config)
    assert error.code == "navigation_blocked"
    assert error.details["reason"] == "non_canonical_host"
    assert error.details["value"] == "münchen.de"
    assert error.message =~ "punycode"
    assert error.message =~ "xn--"
  end

  # ── host_verdict/2: the host rules on a bare string ────────────────────────

  # The read gate judges a host it already has, so the rules have to answer a
  # STRING. A parse → serialise → reparse round trip is where the next bypass
  # lives, and the IPv6 bracket dance it needed is gone with it.
  @host_cases [
    {"169.254.169.254", :blocked, "metadata literal"},
    {"::ffff:169.254.169.254", :blocked, "IPv4-mapped metadata, no brackets to put back"},
    {"metadata.google.internal", :blocked, ".internal suffix"},
    {"192.168.1.1", :blocked, "private literal"},
    {"metadata.google.%69nternal", :blocked, "percent-escaped label"},
    {"169.254.169.254\\.example.com", :blocked, "backslash authority"},
    {"localhost", :allowed, "loopback name"},
    {"127.0.0.1", :allowed, "IPv4 loopback"},
    {"::1", :allowed, "IPv6 loopback"},
    {"example.com", :allowed, "public host"}
  ]

  test "host_verdict/2 answers a bare host string with the same rules as a URL" do
    {:ok, config} = Config.current(allow_private_network: false)

    for {host, expected, why} <- @host_cases do
      actual =
        case Policy.host_verdict(host, config) do
          :ok -> :allowed
          {:error, %{code: "navigation_blocked"}} -> :blocked
        end

      assert actual == expected, "host #{inspect(host)} should be #{expected} (#{why})"
    end
  end

  # ── read_verdict/2: the scheme allow-list ──────────────────────────────────

  # Phrased as the invariant, not as a denylist: NO scheme outside the allow-list
  # yields content. `read_url_allowed/2` was written as "no host ⇒ allow", which
  # had no opinion at all on the scheme dimension, so `file:`, `view-source:`,
  # `filesystem:`, `data:` and `blob:null/` all read.
  @read_cases [
    {"https://example.com/a", :ok, "the network case"},
    {"http://example.com/a", :ok, "the network case, plaintext"},
    {"about:blank", :ok, "Chrome's startup document — a managed profile opens on it"},
    {"about:blank#x", :ok, "query/fragment on about:blank are ignored"},
    {"blob:https://example.com/9d1a-3f", :ok, "in-page PDF/print preview, allowed origin"},
    {"http://169.254.169.254/latest/", "read_blocked", "the host rules still apply"},
    {"blob:http://169.254.169.254/9d1a", "read_blocked", "a blob still names its minter"},
    {"http://metadata.google.internal/", "read_blocked", ".internal suffix"},
    {"file:///etc/passwd", "read_origin_blocked", "local file, hostless spelling"},
    {"file://localhost/etc/passwd", "read_origin_blocked", "local file, host spelling"},
    {"view-source:http://169.254.169.254/", "read_origin_blocked", "source view of a page"},
    {"filesystem:http://169.254.169.254/temporary/x", "read_origin_blocked", "sandboxed fs"},
    {"data:text/html,hi", "read_origin_blocked", "the canonical laundering channel"},
    {"blob:null/9d1a", "read_origin_blocked", "an opaque origin is exactly the three above"},
    {"blob:file:///9d1a", "read_origin_blocked", "file: re-entered through the blob door"},
    {"blob:blob:https://example.com/9d1a", "read_origin_blocked", "one unwrap, never two"},
    {"about:srcdoc", "read_origin_blocked", "not path `blank`"},
    {"chrome://settings", "read_origin_blocked", "browser-internal"},
    {"chrome-untrusted://x", "read_origin_blocked", "browser-internal"},
    {"devtools://devtools/x", "read_origin_blocked", "browser-internal"},
    {"ftp://example.com/f", "read_origin_blocked", "not a readable document origin"},
    {"wyvern://example.com/", "read_origin_blocked", "an unknown scheme refuses by default"},
    {"/relative/path", "read_origin_blocked", "no scheme at all"}
  ]

  test "read_verdict/2 refuses every scheme outside the allow-list" do
    {:ok, config} = Config.current(allow_private_network: false)

    for {url, expected, why} <- @read_cases do
      actual =
        case Policy.read_verdict(url, config) do
          :ok -> :ok
          {:error, %{code: code}} -> code
        end

      assert actual == expected, "read_verdict(#{inspect(url)}) should be #{expected} (#{why})"
    end
  end

  test "a scheme refusal names the recovery that actually works" do
    {:ok, config} = Config.current([])

    assert {:error, error} = Policy.read_verdict("file:///etc/passwd", config)
    assert error.code == "read_origin_blocked"
    assert error.details["value"] == "file"
    assert error.message =~ "file tools"
    refute error.message =~ "Navigate somewhere allowed"
  end

  test "a host refusal on the read path still names the host and the recovery" do
    {:ok, config} = Config.current(allow_private_network: false)

    assert {:error, error} = Policy.read_verdict("http://169.254.169.254/latest/", config)
    assert error.code == "read_blocked"
    assert error.details["value"] == "169.254.169.254"
    assert error.message =~ "169.254.169.254"
    assert error.message =~ "Navigate somewhere allowed"
  end

  # Loopback is the shipped feature the scheme rules must not break.
  test "loopback reads under every allowed_hosts setting" do
    {:ok, narrowed} = Config.current(allow_private_network: false, allowed_hosts: ["example.org"])

    for url <- ["http://localhost:4000/", "http://127.0.0.1:4000/", "http://[::1]:4000/"] do
      assert Policy.read_verdict(url, narrowed) == :ok, "#{url} must stay readable"
    end
  end
end
