defmodule FermixCore.Home.Snapshot.S3EndToEndTest do
  # Opt-in (`--only s3_end_to_end`): the S3 target and a whole snapshot run
  # against MinIO in Docker, with a versioned bucket. The container is started
  # here, named for this run, and removed on exit whatever the outcome.
  use ExUnit.Case, async: false

  alias FermixCore.Home.Epoch
  alias FermixCore.Home.Snapshot
  alias FermixCore.Home.Snapshot.Format
  alias FermixCore.Home.Snapshot.Recipient
  alias FermixCore.Home.Snapshot.Run
  alias FermixCore.Home.Snapshot.S3
  alias FermixCore.Home.Snapshot.S3.SigV4
  alias FermixTestSupport.SafeRm

  @moduletag :s3_end_to_end
  @moduletag timeout: 180_000

  @image "minio/minio:RELEASE.2025-03-12T18-04-18Z"
  @user "fermixinvented"
  @secret "invented-minio-secret"
  @bucket "invented-fermix-snapshots"
  @region "us-east-1"
  @ready_attempts 120

  setup_all do
    name = "fermix-snapshot-minio-#{System.unique_integer([:positive])}"
    port = free_port()

    {_out, 0} =
      System.cmd("docker", [
        "run",
        "-d",
        "--rm",
        "--name",
        name,
        "-p",
        "127.0.0.1:#{port}:9000",
        "-e",
        "MINIO_ROOT_USER=#{@user}",
        "-e",
        "MINIO_ROOT_PASSWORD=#{@secret}",
        @image,
        "server",
        "/data"
      ])

    on_exit(fn -> System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true) end)

    endpoint = "http://127.0.0.1:#{port}"
    :ok = await_ready(endpoint, @ready_attempts)
    {:ok, %{status: 200}} = signed(endpoint, "PUT", "/#{@bucket}", [], "")

    versioning =
      ~s(<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
        "<Status>Enabled</Status></VersioningConfiguration>"

    {:ok, %{status: 200}} =
      signed(endpoint, "PUT", "/#{@bucket}", [{"versioning", ""}], versioning)

    {:ok, pair} = Recipient.from_passphrase("invented-minio-recovery-passphrase")
    %{endpoint: endpoint, pair: pair}
  end

  setup do
    tmp = SafeRm.make_tmp_dir!("snapshot_s3_e2e")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)

    home = Path.join(tmp, "home")
    File.mkdir_p!(home)
    File.write!(Path.join(home, "config.toml"), "[sandbox]\nworkspace_root = \"#{home}/w\"\n")
    File.write!(Path.join(home, "big.bin"), :crypto.strong_rand_bytes(2 * 1_048_576 + 333))
    :ok = Epoch.write(home, 7)

    %{tmp: tmp, home: home}
  end

  test "a snapshot run stores to a versioned bucket, and the object restores", ctx do
    config = [
      recipient: Recipient.encode(ctx.pair),
      s3_bucket: @bucket,
      s3_region: @region,
      s3_endpoint: ctx.endpoint,
      s3_credentials: :keys,
      s3_access_key_id: @user,
      s3_secret_access_key: @secret
    ]

    assert {:ok, %{written: written, outcomes: [{S3, {:ok, %{location: location}}}]}} =
             Run.run(ctx.home, config, [S3], profile: "general", host: "macos-aarch64")

    key = "fermix/general/#{written.name}"
    assert location == "s3://#{@bucket}/#{key}"

    {:ok, response} = signed(ctx.endpoint, "GET", "/#{@bucket}/#{key}", [], "")
    assert response.status == 200
    assert [version | _rest] = Req.Response.get_header(response, "x-amz-version-id")
    assert version not in ["", "null"]
    assert byte_size(response.body) == written.size
    assert Base.encode16(:crypto.hash(:sha256, response.body), case: :lower) == written.sha256

    downloaded = Path.join(ctx.tmp, written.name)
    File.write!(downloaded, response.body)
    into = Path.join(ctx.tmp, "restored")

    {:ok, header} = Format.peek_header(downloaded)
    {:ok, pair} = Recipient.derive("invented-minio-recovery-passphrase", header.salt)

    assert {:ok, %{epoch: 8}} =
             Snapshot.restore(downloaded, pair, into,
               host: "macos-aarch64",
               keyring_usable?: fn -> true end
             )

    assert File.read!(Path.join(into, "big.bin")) == File.read!(Path.join(ctx.home, "big.bin"))
  end

  test "MinIO refuses a body whose checksum differs, in its own words", ctx do
    snapshot = snapshot!(ctx)
    bytes = File.read!(snapshot.path)
    <<head::binary-size(200), byte, rest::binary>> = bytes
    File.write!(snapshot.path, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)

    assert {:error, {:refused, 400, code, message} = reason} =
             S3.store(snapshot, settings(ctx, @secret), profile: "general")

    IO.puts("MinIO checksum refusal: #{code}: #{message}")
    assert S3.sentence(reason) =~ "S3 refused the snapshot (400 #{code}): "
  end

  test "MinIO refuses a wrong secret, in its own words", ctx do
    snapshot = snapshot!(ctx)

    assert {:error, {:refused, 403, "SignatureDoesNotMatch", message}} =
             S3.store(snapshot, settings(ctx, "not-the-secret"), profile: "general")

    IO.puts("MinIO signature refusal: #{message}")
  end

  defp snapshot!(ctx) do
    path = Path.join(ctx.tmp, "out.fxsnap")

    {:ok, written} =
      Snapshot.write(ctx.home, Recipient.public(ctx.pair), path, host: "macos-aarch64")

    Map.put(written, :path, path)
  end

  defp settings(ctx, secret) do
    %{
      bucket: @bucket,
      region: @region,
      prefix: "fermix",
      endpoint: ctx.endpoint,
      credentials: :keys,
      access_key_id: @user,
      secret_access_key: secret
    }
  end

  # A request signed as the target signs its own, for the bucket set-up and the
  # read-back the target never makes.
  defp signed(endpoint, method, path, query, body) do
    uri = URI.parse(endpoint)
    sha256 = Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    headers = [{"host", "#{uri.host}:#{uri.port}"}, {"x-amz-content-sha256", sha256}]

    signed_headers =
      SigV4.sign(
        %{method: method, path: path, query: query, headers: headers, payload_sha256: sha256},
        %{access_key_id: @user, secret_access_key: @secret, session_token: nil},
        %{region: @region, service: "s3", now: DateTime.utc_now()}
      )

    query_string = Enum.map_join(query, "&", fn {k, v} -> "#{k}=#{v}" end)
    url = endpoint <> path <> if(query_string == "", do: "", else: "?" <> query_string)

    Req.request(
      method: method |> String.downcase() |> String.to_existing_atom(),
      url: url,
      headers: headers ++ signed_headers,
      body: body,
      retry: false,
      decode_body: false,
      compressed: false
    )
  end

  # MinIO answers its liveness probe once it serves; the container gives no
  # event to wait on, so the probe is asked a bounded number of times.
  defp await_ready(_endpoint, 0), do: {:error, :minio_not_ready}

  defp await_ready(endpoint, attempts) do
    case Req.get(endpoint <> "/minio/health/live", retry: false, receive_timeout: 1_000) do
      {:ok, %{status: 200}} ->
        :ok

      _not_yet ->
        Process.sleep(250)
        await_ready(endpoint, attempts - 1)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
