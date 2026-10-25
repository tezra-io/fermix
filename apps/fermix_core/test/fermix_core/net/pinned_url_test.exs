defmodule FermixCore.Net.PinnedUrlTest do
  # async: true — every lookup goes through a resolver the test passes in, every
  # egress is a struct the test builds and every response comes from an adapter
  # the test owns: no DNS, no network, no application environment.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias FermixCore.Net.Egress
  alias FermixCore.Net.PinnedUrl

  @host "feeds.example.test"
  @ipv4 {93, 184, 216, 34}
  @ipv6 {0x2A01, 0x4F8, 0xC0C, 0x1D2E, 0, 0, 0, 0x7}
  @direct Egress.new([])
  @proxied Egress.new(proxy: "http://proxy.test:3128")
  @finch_unavailable "Finch was unable to provide a connection within the timeout due to " <>
                       "excess queuing for connections. Consider adjusting the pool size."

  defp answers(ips), do: fn @host -> {:ok, ips} end

  defp pinned(url \\ "https://#{@host}/releases.xml") do
    {:ok, pinned} = PinnedUrl.pin(url, resolver: answers([@ipv4]))
    pinned
  end

  # An adapter that reports each hop it is handed, after `Net.Egress` routed it.
  defp origin(response) do
    parent = self()

    fn request ->
      send(parent, {:hop, request})
      {request, response}
    end
  end

  describe "pin/2" do
    test "puts the checked IPv4 address in the URL and keeps the URL and its host as given" do
      url = "https://#{@host}:8443/releases.xml?page=2#latest"

      assert {:ok, pinned} = PinnedUrl.pin(url, resolver: answers([@ipv4]))

      assert pinned == %PinnedUrl{
               url: "https://93.184.216.34:8443/releases.xml?page=2#latest",
               original_url: url,
               original_host: @host,
               ip: @ipv4
             }
    end

    test "writes a checked IPv6 address in brackets" do
      assert {:ok, pinned} =
               PinnedUrl.pin("https://#{@host}/releases.xml", resolver: answers([@ipv6]))

      assert pinned.url == "https://[2a01:4f8:c0c:1d2e::7]/releases.xml"
      assert URI.parse(pinned.url).host == "2a01:4f8:c0c:1d2e::7"
      assert pinned.ip == @ipv6
      assert pinned.original_host == @host
    end

    test "leaves a URL that already names an address as it is and looks nothing up" do
      refuse_lookup = fn host -> flunk("looked up #{host}") end

      for url <- ["https://93.184.216.34/a", "https://[2a01:4f8:c0c:1d2e::7]/a"] do
        assert {:ok, %PinnedUrl{url: ^url, original_url: ^url, ip: nil}} =
                 PinnedUrl.pin(url, resolver: refuse_lookup)
      end
    end

    test "returns the guard's refusal and pins nothing" do
      url = "https://#{@host}/releases.xml"

      assert PinnedUrl.pin(url, resolver: answers([{10, 0, 0, 7}])) ==
               {:error, {:resolved_to_private_address, {10, 0, 0, 7}}}

      # One private answer among public ones refuses the name, as the guard does.
      assert PinnedUrl.pin(url, resolver: answers([@ipv4, {127, 0, 0, 1}])) ==
               {:error, {:resolved_to_private_address, {127, 0, 0, 1}}}

      assert PinnedUrl.pin(url, resolver: answers([])) ==
               {:error, {:dns_resolution_failed, :nxdomain}}

      assert PinnedUrl.pin("https://169.254.169.254/latest/meta-data/") ==
               {:error, {:blocked_host, :private_address}}
    end
  end

  describe "request_options/2" do
    test "aims at the address, names the host in Host and in TLS, and keeps the caller's options" do
      options =
        PinnedUrl.request_options(pinned(),
          headers: [{"user-agent", "fermix"}],
          connect_options: [timeout: 5_000, transport_opts: [depth: 4]],
          retry: false
        )

      assert options[:url] == "https://93.184.216.34/releases.xml"
      assert options[:headers] == [{"host", @host}, {"user-agent", "fermix"}]
      assert options[:connect_options][:timeout] == 5_000
      assert options[:connect_options][:transport_opts][:server_name_indication] == ~c"#{@host}"
      assert options[:connect_options][:transport_opts][:depth] == 4
      assert options[:retry] == false
    end

    test "replaces a Host, a URL and a redirect choice the caller set" do
      options =
        PinnedUrl.request_options(pinned(),
          headers: [{"Host", "elsewhere.test"}],
          url: "https://elsewhere.test/",
          redirect: true
        )

      assert options[:headers] == [{"host", @host}]
      assert options[:url] == "https://93.184.216.34/releases.xml"
      assert options[:redirect] == false
    end

    test "names no host for a URL that already names an address" do
      {:ok, literal} = PinnedUrl.pin("https://93.184.216.34/a")
      options = [headers: [{"user-agent", "fermix"}], connect_options: [timeout: 5_000]]

      assert Keyword.take(PinnedUrl.request_options(literal, options), [
               :headers,
               :connect_options
             ]) == options
    end

    # A request with its own connect options gets a Finch instance of its own
    # from Req, whose pools otherwise never close an idle connection.
    test "closes the request's pool after 15 s idle, an option Req hands to the pool it starts" do
      options = PinnedUrl.request_options(pinned(), connect_options: [timeout: 5_000])

      assert options[:pool_max_idle_time] == 15_000
      assert Req.Finch.pool_options(options)[:pool_max_idle_time] == 15_000
    end
  end

  describe "request/3" do
    test "routes the request itself: to the checked address for the name, through the proxy" do
      assert {:ok, %{status: 200}} =
               PinnedUrl.request(
                 pinned(),
                 [adapter: origin(Req.Response.new(status: 200)), retry: false],
                 @proxied
               )

      assert_received {:hop, hop}
      assert hop.url.host == "93.184.216.34"
      assert Req.Request.get_header(hop, "host") == [@host]
      assert {:http, "proxy.test", 3128, _phases} = hop.options.connect_options[:proxy]
      assert hop.options.connect_options[:transport_opts][:server_name_indication] == ~c"#{@host}"
    end

    # The URL carries the address, so only the name tells the proxy policy
    # that an operator's `proxy_bypass` entry is about this request.
    test "behind a proxy, an entry in proxy_bypass naming the host still sends it direct" do
      egress = Egress.new(proxy: "http://proxy.test:3128", proxy_bypass: [".example.test"])

      assert {:ok, %{status: 200}} =
               PinnedUrl.request(
                 pinned(),
                 [adapter: origin(Req.Response.new(status: 200))],
                 egress
               )

      assert_received {:hop, hop}
      refute Keyword.has_key?(hop.options.connect_options, :proxy)
      assert hop.options.connect_options[:transport_opts][:inet6] == true
    end

    # Req would follow it by the name, with this hop's Host, TLS name and pin:
    # the caller pins the next hop itself.
    test "hands a redirect back, even to a caller that asked for redirects" do
      moved = Req.Response.new(status: 302, headers: [{"location", "https://other.test/x"}])

      assert {:ok, %{status: 302}} =
               PinnedUrl.request(pinned(), [adapter: origin(moved), redirect: true], @direct)

      assert_received {:hop, _first}
      refute_received {:hop, _followed}
    end

    test "returns a pool with no connection to give as an error, logged by host" do
      adapter = fn _request -> raise RuntimeError, @finch_unavailable end

      {result, log} = with_log(fn -> PinnedUrl.request(pinned(), [adapter: adapter], @direct) end)

      assert {:error, %RuntimeError{message: @finch_unavailable}} = result
      assert log =~ "Pinned request to #{@host} got no connection"
    end

    test "lets any other raise through" do
      adapter = fn _request -> raise RuntimeError, "a bug in the adapter" end

      assert_raise RuntimeError, "a bug in the adapter", fn ->
        PinnedUrl.request(pinned(), [adapter: adapter], @direct)
      end
    end
  end
end
