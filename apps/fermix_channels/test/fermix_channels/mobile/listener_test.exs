defmodule FermixChannels.Mobile.ListenerTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.Listener

  test "builds an isolated HTTPS Bandit listener and permits an ephemeral test port" do
    keyfile = Path.expand("gateway_tls_key.pem", System.tmp_dir!())
    certfile = Path.expand("gateway_tls_cert.pem", System.tmp_dir!())

    assert {:ok, options} =
             Listener.options(
               bind: {127, 0, 0, 1},
               port: 0,
               keyfile: keyfile,
               certfile: certfile,
               identity: identity(keyfile, certfile),
               router_opts: [device_registry: :registry]
             )

    assert options[:scheme] == :https
    assert options[:ip] == {127, 0, 0, 1}
    assert options[:port] == 0
    assert options[:keyfile] == keyfile
    assert options[:certfile] == certfile

    assert {FermixChannels.Mobile.Router, router_opts} = options[:plug]
    assert router_opts[:device_registry] == :registry
    assert router_opts[:identity_root] == identity_root(keyfile)
    assert options[:websocket_options] == [max_frame_size: 65_535, compress: false]
  end

  test "passes only the identity root to sockets, never gateway private key bytes" do
    assert {:ok, options} =
             Listener.options(
               bind: {127, 0, 0, 1},
               port: 0,
               keyfile: "/tmp/key.pem",
               certfile: "/tmp/cert.pem",
               identity: identity("/tmp/key.pem", "/tmp/cert.pem"),
               router_opts: [device_registry: :registry]
             )

    assert {FermixChannels.Mobile.Router, router_opts} = options[:plug]

    assert router_opts[:identity_root] == "/"
    refute Keyword.has_key?(router_opts, :gateway_keypair)
    refute inspect(router_opts) =~ Base.encode16(<<1::256>>)
  end

  test "rejects relative key paths and invalid ports" do
    assert {:error, {:invalid_path, :keyfile}} =
             Listener.options(keyfile: "key.pem", certfile: "/tmp/cert.pem")

    assert {:error, {:invalid_port, -1}} =
             Listener.options(keyfile: "/tmp/key.pem", certfile: "/tmp/cert.pem", port: -1)
  end

  test "starts TLS on an OS-assigned port without touching a fixed port" do
    root =
      Path.join(
        System.tmp_dir!(),
        "fermix-mobile-listener-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    assert {:ok, _identity} = Identity.ensure(root: root)

    listener =
      start_supervised!({Listener, root: root, bind: {127, 0, 0, 1}, port: 0})

    assert {:ok, {{127, 0, 0, 1}, port}} = Listener.listener_info(listener)
    assert port > 0
  end

  test "a dangling identity symlink fails closed instead of looking like a fresh install" do
    root = FermixTestSupport.SafeRm.make_tmp_dir!("mobile-listener-dangling-identity")
    on_exit(fn -> FermixTestSupport.SafeRm.rm_rf!(root) end)
    mobile_dir = Path.join(root, "mobile")
    File.mkdir_p!(mobile_dir)
    File.chmod!(mobile_dir, 0o700)
    File.ln_s!(Path.join(root, "missing-key"), Path.join(mobile_dir, "gateway_key"))

    # The designed stop is an init refusal, so the linked starter must trap the
    # exit to read it instead of dying with the listener it just refused to run.
    Process.flag(:trap_exit, true)

    assert {:error, {:mobile_identity_unavailable, {:identity_incomplete, missing}}} =
             Listener.start_link(name: nil, root: root)

    assert Enum.sort(missing) ==
             Enum.sort([Path.join(mobile_dir, "tls.crt"), Path.join(mobile_dir, "tls.key")])
  end

  defp identity(keyfile, certfile) do
    %Identity{
      gateway_private_key: <<1::256>>,
      gateway_public_key: <<2::256>>,
      tls_private_key: :unused,
      tls_certificate: :unused,
      tls_fingerprint: <<3::256>>,
      tls_key_path: keyfile,
      tls_cert_path: certfile
    }
  end

  defp identity_root(keyfile), do: keyfile |> Path.dirname() |> Path.dirname()
end
