defmodule FermixCore.Net.EgressTransportsTest do
  @moduledoc """
  The transports that cannot tunnel refuse a proxied destination before they
  dial. Each is handed an egress with a proxy and a destination on the open
  internet: the answer is the refusal, and no socket is opened to find it.
  """

  # async: true — the egress is passed in; nothing reads application
  # environment and nothing dials (the refusal comes first).
  use ExUnit.Case, async: true

  alias FermixCore.Capabilities.MCP.Remote.Connection
  alias FermixCore.Capabilities.MCP.Remote.Endpoint
  alias FermixCore.Capabilities.MCP.RuntimeStatus
  alias FermixCore.Meetings.Rtms.Transport.WebSockex, as: RtmsTransport
  alias FermixCore.Net.Egress
  alias FermixCore.Realtime.OpenAIClient
  alias FermixCore.Realtime.OpenAILiveClient
  alias FermixCore.Transcription.WsSocket

  @proxied Egress.new(proxy: "http://proxy.test:3128")
  @refusal {:error, :proxy_unsupported_transport}

  test "the realtime voice socket" do
    assert OpenAIClient.start_link(
             url: "wss://api.openai.com/v1/realtime",
             headers: [],
             parent: self(),
             egress: @proxied
           ) == @refusal
  end

  test "the live voice socket" do
    assert OpenAILiveClient.start_link(
             url: "wss://api.openai.com/v1/live/sessions",
             headers: [],
             parent: self(),
             egress: @proxied
           ) == @refusal
  end

  test "the streaming transcription socket" do
    assert WsSocket.start(
             url: "wss://api.deepgram.com/v1/listen",
             headers: [],
             parent: self(),
             egress: @proxied
           ) == @refusal
  end

  test "the Zoom media socket" do
    assert RtmsTransport.connect("wss://ws.zoom.us/ws", self(), tag: :signaling, egress: @proxied) ==
             @refusal
  end

  # The pinned connector hands Mint the validated address and the signed name
  # separately. Tunnelling it would mean naming one of them to the proxy, and
  # naming the host would let the proxy resolve it again behind the guard.
  test "the pinned remote MCP connector, before it resolves or dials" do
    {:ok, endpoint} = Endpoint.new("https://mcp.vendor.test", "/mcp")
    resolver = fn _host -> flunk("a refused route must not be resolved") end

    refusal = {:remote_security_blocked, :proxy_unsupported_transport}

    assert Connection.open(endpoint, egress: @proxied, resolver: resolver) == {:error, refusal}

    # A block, not unreachability: the owner does not retry it, and the status
    # the log, doctor and the plugin row share names the proxy.
    assert RuntimeStatus.classify(refusal) ==
             {:remote_security_blocked, :proxy_unsupported_transport, nil}
  end
end
