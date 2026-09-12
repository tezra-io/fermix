defmodule FermixCore.Meetings.Rtms.TransportTest do
  # async: true — the assertions are over a pure option list; no socket opens
  # and nothing global is read or written.
  use ExUnit.Case, async: true

  alias FermixCore.Meetings.Rtms.Transport

  describe "WebSockex transport start_options/2" do
    test "verifies the Zoom peer instead of taking WebSockex's insecure default" do
      assert {:ok, opts} =
               Transport.WebSockex.start_options("wss://rtms.example.zoom.us/signaling", 7_000)

      # Without :ssl_options WebSockex connects with verify: :verify_none, and
      # every leg — including the event leg, whose URL carries an OAuth access
      # token — would trust whoever answered.
      ssl_options = Keyword.fetch!(opts, :ssl_options)

      assert ssl_options[:verify] == :verify_peer
      assert ssl_options[:server_name_indication] == ~c"rtms.example.zoom.us"

      assert opts[:handshake_timeout] == 7_000
      assert opts[:async] == false
    end

    test "refuses a URL with no host rather than dialing a peer it cannot verify" do
      # Zoom hands these URLs over at run time (webhook payload, then signaling
      # response), so a hostless one is reachable input, not a typo.
      assert Transport.WebSockex.start_options("rtms.example.zoom.us/signaling", 7_000) ==
               {:error, :ws_url_without_host}

      assert Transport.WebSockex.start_options("wss:///signaling", 7_000) ==
               {:error, :ws_url_without_host}
    end

    test "connect/3 refuses a hostless URL without opening a socket" do
      assert Transport.WebSockex.connect("wss:///signaling", self(), tag: :signaling) ==
               {:error, :ws_url_without_host}
    end
  end
end
