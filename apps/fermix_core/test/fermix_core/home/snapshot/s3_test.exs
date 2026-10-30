defmodule FermixCore.Home.Snapshot.S3Test do
  # The S3 target against a local stand-in for S3 (Bandit and a Plug in this
  # file): a stored snapshot, a checksum S3 refuses, an authorization S3
  # refuses, and the credentials each mode reads.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Snapshot.S3
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @now ~U[2026-10-27 09:30:00Z]

  defmodule FakeS3 do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    # Reads the whole body as S3 would, checks the checksum the request
    # carries, reports what arrived to the test, and answers as `mode` says.
    @impl true
    def call(conn, %{test: test, mode: mode}) do
      {body, conn} = read_all(conn, [])
      digest = :crypto.hash(:sha256, body)
      sent = conn |> get_req_header("x-amz-checksum-sha256") |> List.first()

      send(test, {:fake_s3, conn.method, conn.request_path, conn.req_headers, body})
      answer(conn, mode, sent == Base.encode64(digest), Base.encode64(digest))
    end

    defp answer(conn, :store, true, checksum) do
      conn |> put_resp_header("x-amz-checksum-sha256", checksum) |> send_resp(200, "")
    end

    defp answer(conn, :store, false, _checksum) do
      send_resp(
        conn,
        400,
        error("BadDigest", "The SHA256 you specified did not match the calculated checksum.")
      )
    end

    defp answer(conn, :escaped, _matches, _checksum) do
      send_resp(
        conn,
        400,
        error(
          "XAmzContentSHA256Mismatch",
          "The provided &#39;x-amz-content-sha256&#39; header &amp; &#x27;body&#x27; differ."
        )
      )
    end

    defp answer(conn, :deny, _matches, _checksum) do
      send_resp(
        conn,
        403,
        error(
          "SignatureDoesNotMatch",
          "The request signature we calculated does not match the signature you provided."
        )
      )
    end

    defp answer(conn, :echo_other, _matches, _checksum) do
      conn
      |> put_resp_header("x-amz-checksum-sha256", Base.encode64(<<0::256>>))
      |> send_resp(200, "")
    end

    defp error(code, message) do
      ~s(<?xml version="1.0" encoding="UTF-8"?>\n<Error><Code>#{code}</Code>) <>
        "<Message>#{message}</Message><RequestId>invented</RequestId></Error>"
    end

    defp read_all(conn, acc) do
      case read_body(conn) do
        {:ok, data, conn} -> {IO.iodata_to_binary([acc | data]), conn}
        {:more, data, conn} -> read_all(conn, [acc | data])
      end
    end
  end

  setup do
    tmp = SafeRm.make_tmp_dir!("snapshot_s3")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  describe "a PUT to an S3-compatible host" do
    test "streams the file, signs it and is verified when S3 accepts the checksum", %{tmp: tmp} do
      settings = settings(fake_s3!(:store))
      snapshot = snapshot!(tmp, :crypto.strong_rand_bytes(3 * 1_048_576 + 17))

      assert {:ok, %{location: location}} = S3.store(snapshot, settings, opts())
      assert location == "s3://invented-bucket/fermix/general/20261027T093000Z-e4.fxsnap"

      assert_receive {:fake_s3, "PUT", path, headers, body}
      assert path == "/invented-bucket/fermix/general/20261027T093000Z-e4.fxsnap"
      assert body == File.read!(snapshot.path)
      assert header(headers, "x-amz-content-sha256") == snapshot.sha256
      assert header(headers, "content-length") == Integer.to_string(snapshot.size)
      refute header(headers, "transfer-encoding")

      authorization = header(headers, "authorization")

      assert authorization =~
               "Credential=AKIAINVENTED/20261027/eu-west-1/s3/aws4_request, " <>
                 "SignedHeaders=content-length;host;x-amz-checksum-sha256;" <>
                 "x-amz-content-sha256;x-amz-date, Signature="
    end

    test "a checksum S3 refuses is the failure, in S3's own words", %{tmp: tmp} do
      settings = settings(fake_s3!(:store))
      snapshot = snapshot!(tmp, "invented snapshot bytes")
      # The file changed after its digest was taken, at the same length: S3
      # computes another digest.
      File.write!(snapshot.path, "invented snapshot bytez")

      assert {:error, {:refused, 400, "BadDigest", message} = reason} =
               S3.store(snapshot, settings, opts())

      assert message == "The SHA256 you specified did not match the calculated checksum."

      assert S3.sentence(reason) ==
               "S3 refused the snapshot (400 BadDigest): The SHA256 you specified did not " <>
                 "match the calculated checksum."
    end

    test "an authorization S3 refuses is the failure, in S3's own words", %{tmp: tmp} do
      settings = settings(fake_s3!(:deny))

      assert {:error, {:refused, 403, "SignatureDoesNotMatch", _message} = reason} =
               S3.store(snapshot!(tmp, "bytes"), settings, opts())

      assert S3.sentence(reason) =~
               "S3 refused the snapshot (403 SignatureDoesNotMatch): The request"
    end

    test "the vendor's escaped words are read back as words", %{tmp: tmp} do
      settings = settings(fake_s3!(:escaped))

      assert {:error, {:refused, 400, "XAmzContentSHA256Mismatch", message}} =
               S3.store(snapshot!(tmp, "bytes"), settings, opts())

      assert message == "The provided 'x-amz-content-sha256' header & 'body' differ."
    end

    test "an answer echoing another checksum is not counted as stored", %{tmp: tmp} do
      settings = settings(fake_s3!(:echo_other))

      assert {:error, {:checksum_mismatch, _echoed}} =
               S3.store(snapshot!(tmp, "bytes"), settings, opts())
    end

    test "an unreachable host says why", %{tmp: tmp} do
      settings = settings("http://127.0.0.1:1")

      assert {:error, {:unreachable, reason} = error} =
               S3.store(snapshot!(tmp, "bytes"), settings, opts())

      assert is_binary(reason)
      assert S3.sentence(error) =~ "S3 could not be reached: "
    end

    test "a snapshot beyond one PUT is refused before anything is sent", %{tmp: tmp} do
      snapshot = %{snapshot!(tmp, "bytes") | size: 5_368_709_121}

      assert S3.store(snapshot, settings("http://127.0.0.1:1"), opts()) ==
               {:error, {:too_large, 5_368_709_121, 5_368_709_120}}
    end
  end

  describe "instance-profile credentials" do
    test "are read from the timer's file, session token included", %{tmp: tmp} do
      file = credentials_file!(tmp, "2026-10-27T15:00:00Z")
      settings = %{settings(fake_s3!(:store)) | credentials: :instance_profile}

      assert {:ok, _stored} =
               S3.store(snapshot!(tmp, "bytes"), settings, opts(instance_credentials_file: file))

      assert_receive {:fake_s3, "PUT", _path, headers, _body}
      assert header(headers, "x-amz-security-token") == "invented-session-token"
      assert header(headers, "authorization") =~ "Credential=ASIAINVENTED/"
      assert header(headers, "authorization") =~ ";x-amz-security-token, Signature="
    end

    test "missing, expired or malformed, each by name", %{tmp: tmp} do
      settings = %{settings("http://127.0.0.1:1") | credentials: :instance_profile}
      snapshot = snapshot!(tmp, "bytes")
      missing = Path.join(tmp, "absent.json")

      assert {:error, {:instance_credentials, :absent} = absent} =
               S3.store(snapshot, settings, opts(instance_credentials_file: missing))

      assert S3.sentence(absent) =~ "no instance credentials at /run/fermix/aws-credentials.json"

      expired = credentials_file!(tmp, "2026-10-27T09:30:30Z")

      assert {:error, {:instance_credentials, {:expired, ~U[2026-10-27 09:30:30Z]}}} =
               S3.store(snapshot, settings, opts(instance_credentials_file: expired))

      malformed = Path.join(tmp, "malformed.json")
      File.write!(malformed, ~s({"AccessKeyId": "x"}))

      assert {:error, {:instance_credentials, :invalid}} =
               S3.store(snapshot, settings, opts(instance_credentials_file: malformed))
    end
  end

  describe "access keys" do
    test "a reference the settings load could not resolve is read from its store",
         %{tmp: tmp} do
      # Only this test stores these two keys, and it deletes exactly them, so
      # the shared stub table is left as every other test sees it.
      :ok = SecretWriterStub.put(:snapshot_s3_access_key_id, "AKIASTORED", store: :file)
      :ok = SecretWriterStub.put(:snapshot_s3_secret_access_key, "stored-secret", store: :file)

      on_exit(fn ->
        SecretWriterStub.delete(:snapshot_s3_access_key_id, store: :file)
        SecretWriterStub.delete(:snapshot_s3_secret_access_key, store: :file)
      end)

      settings = %{
        settings(fake_s3!(:store))
        | access_key_id: "@file",
          secret_access_key: "@file"
      }

      assert {:ok, _stored} = S3.store(snapshot!(tmp, "bytes"), settings, opts())
      assert_receive {:fake_s3, "PUT", _path, headers, _body}
      assert header(headers, "authorization") =~ "Credential=AKIASTORED/"
    end

    test "keys that are not stored are refused by name", %{tmp: tmp} do
      settings = %{settings("http://127.0.0.1:1") | access_key_id: nil}

      assert {:error, {:keys_missing, :snapshot_s3_access_key_id} = reason} =
               S3.store(snapshot!(tmp, "bytes"), settings, opts())

      assert S3.sentence(reason) ==
               "The S3 access keys are not stored: set `snapshot_s3_access_key_id` and try again."
    end
  end

  test "AWS is addressed virtual-hosted and the destination names the profile" do
    settings = %{settings("http://unused") | endpoint: nil}

    assert S3.destination(settings, profile: "work") == "s3://invented-bucket/fermix/work/"
    assert S3.key(settings, "n.fxsnap", profile: "work") == "fermix/work/n.fxsnap"

    assert S3.url(settings, "fermix/work/n.fxsnap") ==
             "https://invented-bucket.s3.eu-west-1.amazonaws.com/fermix/work/n.fxsnap"
  end

  test "a bucket named with dots is addressed path-style, which S3's certificate covers" do
    settings = %{settings("http://unused") | endpoint: nil, bucket: "invented.dotted.bucket"}

    assert S3.url(settings, "fermix/work/n.fxsnap") ==
             "https://s3.eu-west-1.amazonaws.com/invented.dotted.bucket/fermix/work/n.fxsnap"
  end

  defp fake_s3!(mode) do
    server =
      start_supervised!(
        {Bandit,
         plug: {FakeS3, %{test: self(), mode: mode}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp settings(endpoint) do
    %{
      bucket: "invented-bucket",
      region: "eu-west-1",
      prefix: "fermix",
      endpoint: endpoint,
      credentials: :keys,
      access_key_id: "AKIAINVENTED",
      secret_access_key: "invented-secret"
    }
  end

  defp opts(extra \\ []), do: [profile: "general", now: fn -> @now end] ++ extra

  defp snapshot!(tmp, bytes) do
    path = Path.join(tmp, "#{System.unique_integer([:positive])}.fxsnap")
    File.write!(path, bytes)

    %{
      path: path,
      name: "20261027T093000Z-e4.fxsnap",
      sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
      size: byte_size(bytes),
      epoch: 4,
      created_at: @now
    }
  end

  defp credentials_file!(tmp, expiration) do
    path = Path.join(tmp, "aws-credentials-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "Code" => "Success",
        "AccessKeyId" => "ASIAINVENTED",
        "SecretAccessKey" => "invented-instance-secret",
        "Token" => "invented-session-token",
        "Expiration" => expiration
      })
    )

    path
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end
