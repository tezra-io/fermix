defmodule FermixCore.Net.Tls do
  @moduledoc """
  The TLS client posture every outbound `wss://` socket connects under.

  It exists because `WebSockex` fails open. `WebSockex.Conn.new/2` defaults
  `insecure: true`, and that branch hands `:ssl.connect/4` a bare
  `verify: :verify_none` — so a socket opened without an explicit
  `:ssl_options` accepts *any* certificate. An active network attacker can then
  impersonate the vendor endpoint and read the API key or bearer token out of
  the handshake headers, plus everything that follows on the socket. Nothing at
  the call site says so: the insecure default is invisible from there and there
  is no error and no log line when it applies.

  `:ssl_options` is what closes it. WebSockex merges the list over
  `[mode: :binary, active: false, packet: 0]` and never consults `:insecure` or
  `:cacerts` again, so this option set *replaces* the insecure default outright.
  That is also why every `wss://` call site has to route through here rather
  than assemble its own: one that forgets silently gets `verify_none` back.

  Every option is spelled out rather than left to an `:ssl` default, the way
  `FermixCore.Capabilities.MCP.Remote.Connection` spells out the same set. This
  is an audited path, and an implicit default is not something a reviewer can
  confirm from the call site.
  """

  @doc """
  TLS client options that verify the peer presenting itself as `host`.

  `host` drives both SNI and the certificate hostname check, so it must be the
  name the caller intends to talk to — derived from the URL being dialed, never
  a value the peer supplies during the connection.

  Options:

    * `:cacerts` — the trust store to verify against. Defaults to the OS store
      (`:public_key.cacerts_get/0`), the same anchor the remote-MCP rail uses.
      Overriding it is how a test pins a throwaway certificate and proves a
      *trusted* chain still completes the handshake; production never passes it.
  """
  @spec client_options(String.t(), keyword()) :: [:ssl.tls_client_option()]
  def client_options(host, opts \\ []) when is_binary(host) and host != "" and is_list(opts) do
    [
      verify: :verify_peer,
      cacerts: Keyword.get_lazy(opts, :cacerts, &:public_key.cacerts_get/0),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
