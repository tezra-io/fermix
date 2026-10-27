defmodule FermixCore.Net.GuardTest do
  use ExUnit.Case, async: true

  alias FermixCore.Net.Guard

  test "allows public http and https hosts after DNS preflight" do
    resolver = fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end

    assert :ok = Guard.validate("https://example.com/path", resolver: resolver)
    assert :ok = Guard.validate("http://example.com/path", resolver: resolver)
  end

  test "rejects non-http schemes, whitespace, localhost, and local domains" do
    assert {:error, :scheme_not_http_or_https} = Guard.validate("file:///etc/passwd")
    assert {:error, :url_has_whitespace} = Guard.validate("https://example.com/a b")
    assert {:error, {:blocked_host, :localhost}} = Guard.validate("http://localhost:4000")
    assert {:error, {:blocked_host, :local_domain}} = Guard.validate("http://printer.local")
  end

  # A cue stream's address is `wss://` (M60 §3.2): the same public-web policy,
  # asked for that scheme explicitly. Every other caller keeps http and https.
  test "takes the schemes it is given in place of http and https, under the same policy" do
    resolver = fn "news.example.test" -> {:ok, [{203, 0, 114, 21}]} end

    assert {:ok, {203, 0, 114, 21}} =
             Guard.resolve_and_validate("wss://news.example.test/v1/news",
               schemes: ["wss"],
               resolver: resolver
             )

    assert {:error, {:scheme_not_allowed, ["wss"]}} =
             Guard.resolve_and_validate("https://news.example.test/v1/news",
               schemes: ["wss"],
               resolver: resolver
             )

    assert {:error, :scheme_not_http_or_https} =
             Guard.resolve_and_validate("wss://news.example.test/v1/news", resolver: resolver)

    cgnat = fn "relay.example.test" -> {:ok, [{100, 64, 0, 9}]} end

    assert {:error, {:resolved_to_private_address, {100, 64, 0, 9}}} =
             Guard.resolve_and_validate("wss://relay.example.test",
               schemes: ["wss"],
               resolver: cgnat
             )
  end

  test "blocks private IP literals and IPv4-mapped IPv6 literals" do
    assert {:error, {:blocked_host, :private_address}} =
             Guard.validate("http://169.254.169.254/latest/meta-data")

    assert {:error, {:blocked_host, :private_address}} =
             Guard.validate("http://[::ffff:127.0.0.1]/")
  end

  test "blocks DNS answers that resolve to private addresses" do
    resolver = fn "safe-looking.example" -> {:ok, [{169, 254, 169, 254}]} end

    assert {:error, {:resolved_to_private_address, {169, 254, 169, 254}}} =
             Guard.validate("https://safe-looking.example", resolver: resolver)
  end

  test "blocks IPv4 literals in CGNAT, documentation, benchmarking, and 6to4 relay ranges" do
    for host <- [
          "100.64.0.1",
          "100.127.255.254",
          "192.0.2.1",
          "198.51.100.1",
          "203.0.113.1",
          "198.18.0.1",
          "198.19.255.254",
          "192.88.99.1"
        ] do
      assert {:error, {:blocked_host, :private_address}} = Guard.validate("http://#{host}/"),
             "expected #{host} to be rejected as non-global"
    end
  end

  test "blocks IPv6 literals in unspecified, IPv4-compatible, and transition ranges" do
    for host <- [
          "[::]",
          "[::1.2.3.4]",
          "[2002::1]",
          "[2002:c058:6301::1]",
          "[2001:0:4136:e378::1]",
          "[64:ff9b::1.2.3.4]"
        ] do
      assert {:error, {:blocked_host, :private_address}} = Guard.validate("http://#{host}/"),
             "expected #{host} to be rejected as non-global"
    end
  end

  test "keeps blocking the previously rejected literal ranges" do
    for host <- [
          "10.1.2.3",
          "127.0.0.1",
          "0.0.0.0",
          "169.254.169.254",
          "192.168.1.1",
          "172.16.0.1",
          "172.31.255.254",
          "224.0.0.1",
          "239.255.255.250",
          "240.0.0.1",
          "255.255.255.255",
          "[::1]",
          "[::ffff:10.0.0.1]",
          "[fc00::1]",
          "[fd12:3456::1]",
          "[fe80::1]",
          "[ff02::1]"
        ] do
      assert {:error, {:blocked_host, :private_address}} = Guard.validate("http://#{host}/"),
             "expected #{host} to be rejected as non-global"
    end
  end

  test "allows real public addresses as literals and as DNS answers" do
    public = [{1, 1, 1, 1}, {8, 8, 8, 8}, {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}]

    for host <- ["1.1.1.1", "8.8.8.8", "[2606:4700:4700::1111]"] do
      assert :ok = Guard.validate("https://#{host}/"), "expected #{host} to be allowed"
    end

    resolver = fn "resolver.example" -> {:ok, public} end

    assert {:ok, {1, 1, 1, 1}} =
             Guard.resolve_and_validate("https://resolver.example", resolver: resolver)
  end

  test "rejects a mixed answer set even when the first answer is public" do
    resolver = fn "rebind.example" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 5}]} end

    assert {:error, {:resolved_to_private_address, {10, 0, 0, 5}}} =
             Guard.validate("https://rebind.example", resolver: resolver)
  end

  test "rejects a mixed answer set whose non-global answer is a v6 transition address" do
    answers = [
      {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111},
      {0x2002, 0xC058, 0x6301, 0, 0, 0, 0, 1}
    ]

    resolver = fn "sixtofour.example" -> {:ok, answers} end

    assert {:error, {:resolved_to_private_address, {0x2002, 0xC058, 0x6301, 0, 0, 0, 0, 1}}} =
             Guard.validate("https://sixtofour.example", resolver: resolver)
  end

  test "returns the first answer when every answer is globally routable" do
    answers = [{93, 184, 216, 34}, {8, 8, 4, 4}, {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}]
    resolver = fn "multi.example" -> {:ok, answers} end

    assert :ok = Guard.validate("https://multi.example", resolver: resolver)

    assert {:ok, {93, 184, 216, 34}} =
             Guard.resolve_and_validate("https://multi.example", resolver: resolver)
  end

  test "reports an empty answer list as a DNS resolution failure" do
    resolver = fn "empty.example" -> {:ok, []} end

    assert {:error, {:dns_resolution_failed, :nxdomain}} =
             Guard.validate("https://empty.example", resolver: resolver)
  end

  test "validates redirect targets with the same rules" do
    resolver = fn
      "example.com" -> {:ok, [{93, 184, 216, 34}]}
      "localhost" -> {:ok, [{127, 0, 0, 1}]}
    end

    assert {:error, {:blocked_host, :localhost}} =
             Guard.validate_redirect("http://localhost/private", "https://example.com",
               resolver: resolver
             )
  end

  # The narrower question a caller that lets the operator's own network through
  # still asks: link-local (where every instance-metadata endpoint lives), the
  # unspecified address, and AWS's IPv6 metadata endpoint. The allows are as
  # load-bearing as the refusals — RFC 1918, ULA, CGNAT (tailnets) and loopback
  # are the intranet, homelab and dev-server cases this question must not touch.
  @link_local_cases [
    {{169, 254, 169, 254}, true, "cloud instance metadata"},
    {{169, 254, 10, 20}, true, "IPv4 link-local"},
    {{0, 0, 0, 0}, true, "IPv4 unspecified"},
    {{0, 1, 2, 3}, true, "0.0.0.0/8, this host"},
    {{0, 0, 0, 0, 0, 0, 0, 0}, true, "IPv6 unspecified"},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 1}, true, "IPv6 link-local"},
    {{0xFEBF, 0, 0, 0, 0, 0, 0, 1}, true, "top of fe80::/10"},
    {{0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254}, true, "AWS IPv6 metadata endpoint"},
    {{0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}, true, "IPv4-mapped metadata"},
    {{10, 0, 0, 5}, false, "RFC 1918 — an intranet host or a proxy"},
    {{192, 168, 1, 1}, false, "RFC 1918 — a home router"},
    {{100, 64, 0, 1}, false, "CGNAT — a tailnet peer"},
    {{127, 0, 0, 1}, false, "IPv4 loopback"},
    {{0, 0, 0, 0, 0, 0, 0, 1}, false, "IPv6 loopback"},
    {{0xFD12, 0x3456, 0, 0, 0, 0, 0, 1}, false, "ULA other than the metadata endpoint"},
    {{0xFEC0, 0, 0, 0, 0, 0, 0, 1}, false, "site-local is not link-local"},
    {{93, 184, 216, 34}, false, "public IPv4"},
    {{0x2606, 0x4700, 0, 0, 0, 0, 0, 1}, false, "public IPv6"}
  ]

  test "metadata_or_link_local?/1 answers link-local, metadata and unspecified only" do
    for {ip, expected, why} <- @link_local_cases do
      assert Guard.metadata_or_link_local?(ip) == expected,
             "#{:inet.ntoa(ip)} should be #{expected} (#{why})"
    end
  end

  # One classifier, two questions: whatever the narrow question refuses, the
  # public-web check refuses too.
  test "every address metadata_or_link_local?/1 refuses is non-global to validate/2" do
    for {ip, true, why} <- @link_local_cases do
      resolver = fn "answer.example" -> {:ok, [ip]} end

      assert {:error, {:resolved_to_private_address, ^ip}} =
               Guard.validate("https://answer.example", resolver: resolver),
             "validate/2 let through #{:inet.ntoa(ip)} (#{why})"
    end
  end

  describe "owner_peers/2 (an address the owner typed, M74 E4)" do
    test "admits loopback, private ranges and IP literals the public policy refuses" do
      for {url, ip} <- [
            {"https://127.0.0.1:8443/mcp", {127, 0, 0, 1}},
            {"https://[::1]/mcp", {0, 0, 0, 0, 0, 0, 0, 1}},
            {"https://10.0.0.5/mcp", {10, 0, 0, 5}},
            {"https://172.16.4.2/mcp", {172, 16, 4, 2}},
            {"https://192.168.1.20/mcp", {192, 168, 1, 20}},
            {"https://100.64.0.1/mcp", {100, 64, 0, 1}},
            {"https://[fd12:3456::1]/mcp", {0xFD12, 0x3456, 0, 0, 0, 0, 0, 1}}
          ] do
        assert Guard.owner_peers(url) == {:ok, [ip]}, url
        assert {:error, _refused} = Guard.validate(url), "the public policy let #{url} through"
      end

      assert Guard.owner_peers("https://93.184.216.34/mcp") == {:ok, [{93, 184, 216, 34}]}
    end

    # The system resolver's answers, every one of them, in its order: a server
    # bound to only one of `localhost`'s addresses is still reached.
    test "keeps every answer for a name, in order, localhost included" do
      resolver = fn "localhost" -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}]} end

      assert Guard.owner_peers("http://localhost:3000/mcp", resolver: resolver) ==
               {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}, {127, 0, 0, 1}]}

      resolver = fn "nas.home.example" ->
        {:ok, [{192, 168, 1, 20}, {10, 0, 0, 5}, {10, 0, 0, 5}]}
      end

      assert Guard.owner_peers("https://nas.home.example/mcp", resolver: resolver) ==
               {:ok, [{192, 168, 1, 20}, {10, 0, 0, 5}]}
    end

    # The public policy refuses `.local` by name; the owner's mDNS names are
    # theirs, and resolve through the system resolver.
    test "resolves a .local name through the system resolver" do
      resolver = fn "nas.local" -> {:ok, [{192, 168, 1, 20}]} end

      assert Guard.owner_peers("https://nas.local/mcp", resolver: resolver) ==
               {:ok, [{192, 168, 1, 20}]}

      assert {:error, {:blocked_host, :local_domain}} = Guard.validate("https://nas.local/mcp")
    end

    test "refuses a link-local or metadata literal" do
      for url <- [
            "http://169.254.169.254/latest/meta-data",
            "https://169.254.10.1/mcp",
            "https://[fe80::1]/mcp",
            "https://[fd00:ec2::254]/mcp",
            "https://[::ffff:169.254.169.254]/mcp",
            "https://0.0.0.0/mcp"
          ] do
        assert {:error, {:blocked_host, :link_local_address}} = Guard.owner_peers(url), url
      end
    end

    test "refuses a name any of whose answers is link-local or metadata" do
      for {ip, true, why} <- @link_local_cases do
        resolver = fn "answer.example" -> {:ok, [{10, 0, 0, 5}, ip]} end

        assert {:error, {:resolved_to_link_local_address, ^ip}} =
                 Guard.owner_peers("https://answer.example/mcp", resolver: resolver),
               "the owner policy let through #{:inet.ntoa(ip)} (#{why})"
      end
    end

    test "a name with no answer is a failed lookup" do
      assert {:error, {:dns_resolution_failed, :nxdomain}} =
               Guard.owner_peers("https://gone.example/mcp", resolver: fn _host -> {:ok, []} end)

      assert {:error, {:dns_resolution_failed, :timeout}} =
               Guard.owner_peers("https://gone.example/mcp",
                 resolver: fn _host -> {:error, :timeout} end
               )
    end

    test "loopback_host?/1 answers this machine only" do
      for host <- [
            "localhost",
            "API.localhost",
            "127.0.0.1",
            "127.9.9.9",
            "::1",
            "::ffff:127.0.0.1"
          ] do
        assert Guard.loopback_host?(host), host
      end

      for host <- ["10.0.0.5", "192.168.1.1", "::", "0.0.0.0", "localhost.example", "example.com"] do
        refute Guard.loopback_host?(host), host
      end
    end
  end

  # What the lookup itself refuses — a host that is not UTF-8, a name with an
  # empty or overlong label — is a failed lookup the caller judges, never a
  # crash in the process that asked. Each is refused before any query is sent.
  test "resolve/2 answers a name it cannot look up with an error" do
    for host <- [<<0xFF, 0xFE>>, "a..example", String.duplicate("a", 64) <> ".example"] do
      assert {:error, _reason} = Guard.resolve(host, 100), "#{inspect(host)} raised"
    end
  end

  test "redacts sensitive headers case-insensitively" do
    headers = [
      {"Authorization", "Bearer abc"},
      {"cookie", "sid=1"},
      {"x-api-key", "secret"},
      {"X-Subscription-Token", "brave-secret"},
      {"Content-Type", "text/html"}
    ]

    assert Guard.redact_headers(headers) == [
             {"Authorization", "***REDACTED***"},
             {"cookie", "***REDACTED***"},
             {"x-api-key", "***REDACTED***"},
             {"X-Subscription-Token", "***REDACTED***"},
             {"Content-Type", "text/html"}
           ]
  end

  test "redacts headers into a JSON-safe trace shape" do
    headers = %{"Authorization" => "Bearer abc", "Content-Type" => "text/html"}

    assert Guard.redact_headers_for_trace(headers) == [
             %{name: "Authorization", value: "***REDACTED***"},
             %{name: "Content-Type", value: "text/html"}
           ]
  end
end
