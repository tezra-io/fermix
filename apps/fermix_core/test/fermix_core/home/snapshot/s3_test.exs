defmodule FermixCore.Home.Snapshot.S3Test do
  # The S3 target against a local stand-in for S3 (Bandit and a Plug in this
  # file): a stored snapshot, a checksum S3 refuses, an authorization S3
  # refuses, the access keys it signs with, and the instance role's session
  # (E1).
  use ExUnit.Case, async: true

  alias FermixCore.Home.Snapshot.S3
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @now ~U[2026-10-27 09:30:00Z]
  @session_token "IQoJb3JpZ2luX2VjEInventedSessionToken+/="

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

    defp answer(conn, :wrong_owner, _matches, _checksum),
      do: send_resp(conn, 403, error("AccessDenied", "Access Denied"))

    defp answer(conn, :no_bucket, _matches, _checksum),
      do: send_resp(conn, 404, error("NoSuchBucket", "The specified bucket does not exist"))

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

  # E1: on an Always On server whose infrastructure set the bucket, root's
  # credentials helper writes a one-hour session of the snapshot writer role
  # into a directory the engine's account reads (`/run/fermix-snapshots`),
  # and the target signs with it, its token included.
  describe "the instance role's session" do
    test "signs with the session the helper wrote, its token signed", %{tmp: tmp} do
      write_session!(tmp, ~U[2026-10-27 10:30:00Z])
      settings = instance_role(fake_s3!(:store))

      assert {:ok, _stored} = S3.store(snapshot!(tmp, "bytes"), settings, opts(tmp))
      assert_receive {:fake_s3, "PUT", _path, headers, _body}
      assert header(headers, "x-amz-security-token") == @session_token

      assert header(headers, "authorization") =~
               "Credential=ASIAINVENTEDSESSION/20261027/eu-west-1/s3/aws4_request, " <>
                 "SignedHeaders=content-length;host;x-amz-checksum-sha256;" <>
                 "x-amz-content-sha256;x-amz-date;x-amz-expected-bucket-owner;" <>
                 "x-amz-security-token, Signature="
    end

    # Security review: the bucket's name is predictable and S3's names are
    # global, so an upload names the account the helper's session belongs to
    # as the bucket's owner, signed; a bucket of that name in another account
    # refuses it.
    test "names the session's account as the bucket's owner", %{tmp: tmp} do
      write_session!(tmp, ~U[2026-10-27 10:30:00Z])

      assert {:ok, _stored} =
               S3.store(snapshot!(tmp, "bytes"), instance_role(fake_s3!(:store)), opts(tmp))

      assert_receive {:fake_s3, "PUT", _path, headers, _body}
      assert header(headers, "x-amz-expected-bucket-owner") == "111122223333"
    end

    test "a bucket that is not the owner's refuses in a sentence of its own", %{tmp: tmp} do
      write_session!(tmp, ~U[2026-10-27 10:30:00Z])

      assert {:error,
              {:not_the_owners_bucket, "invented-bucket", "111122223333", 403, "Access Denied"} =
                reason} =
               S3.store(snapshot!(tmp, "bytes"), instance_role(fake_s3!(:wrong_owner)), opts(tmp))

      assert S3.sentence(reason) ==
               "S3 refused the snapshot (403 AccessDenied): Access Denied. Fermix puts it " <>
                 "only into a bucket of the account 111122223333, and this server's session " <>
                 "may write only there: the bucket invented-bucket may belong to another account."

      assert {:error, {:refused, 404, "NoSuchBucket", "The specified bucket does not exist"}} =
               S3.store(snapshot!(tmp, "bytes"), instance_role(fake_s3!(:no_bucket)), opts(tmp))
    end

    test "access keys name no owner, which only the session knows", %{tmp: tmp} do
      assert {:ok, _stored} =
               S3.store(snapshot!(tmp, "bytes"), settings(fake_s3!(:store)), opts())

      assert_receive {:fake_s3, "PUT", _path, headers, _body}
      refute header(headers, "x-amz-expected-bucket-owner")
      refute header(headers, "x-amz-security-token")
    end

    test "no session yet says so, with the helper's own last words", %{tmp: tmp} do
      File.write!(
        Path.join(tmp, "error"),
        "AWS STS refused the snapshot session (AccessDenied: not authorized).\n"
      )

      assert {:error, {:session_missing, said} = reason} =
               S3.store(snapshot!(tmp, "bytes"), instance_role("http://127.0.0.1:1"), opts(tmp))

      assert said == "AWS STS refused the snapshot session (AccessDenied: not authorized)."

      assert S3.sentence(reason) ==
               "The server's credentials helper has handed Fermix no S3 session yet. Its " <>
                 "last try: AWS STS refused the snapshot session (AccessDenied: not authorized)."

      File.rm!(Path.join(tmp, "error"))

      assert {:error, {:session_missing, nil} = quiet} =
               S3.store(snapshot!(tmp, "bytes"), instance_role("http://127.0.0.1:1"), opts(tmp))

      assert S3.sentence(quiet) ==
               "The server's credentials helper has handed Fermix no S3 session yet: " <>
                 "fermix-snapshot-credentials.timer runs it every 15 minutes."
    end

    test "an expired session is refused before anything is sent", %{tmp: tmp} do
      write_session!(tmp, ~U[2026-10-27 09:30:30Z])
      File.write!(Path.join(tmp, "error"), "The instance metadata service did not answer.\n")

      assert {:error, {:session_expired, ~U[2026-10-27 09:30:30Z], said} = reason} =
               S3.store(snapshot!(tmp, "bytes"), instance_role("http://127.0.0.1:1"), opts(tmp))

      assert said == "The instance metadata service did not answer."

      assert S3.sentence(reason) ==
               "The S3 session the server's credentials helper handed Fermix ran out at " <>
                 "2026-10-27T09:30:30Z. Its last try: The instance metadata service did not answer."
    end

    test "a session not in the helper's shape is refused by name", %{tmp: tmp} do
      write_session!(tmp, ~U[2026-10-27 10:30:00Z], account_id: "not an account")

      assert {:error, :session_malformed = reason} =
               S3.store(snapshot!(tmp, "bytes"), instance_role("http://127.0.0.1:1"), opts(tmp))

      assert S3.sentence(reason) ==
               "The S3 session file the server's credentials helper wrote is not in its shape."
    end

    test "a session that cannot be read says why", %{tmp: tmp} do
      File.mkdir_p!(Path.join(tmp, "credentials.json"))

      assert {:error, {:session_unreadable, :eisdir} = reason} =
               S3.store(snapshot!(tmp, "bytes"), instance_role("http://127.0.0.1:1"), opts(tmp))

      assert S3.sentence(reason) ==
               "Fermix could not read the S3 session the server's credentials helper " <>
                 "wrote: illegal operation on a directory."
    end

    test "access keys never fall back to a session", %{tmp: tmp} do
      write_session!(tmp, ~U[2026-10-27 10:30:00Z])
      settings = %{settings("http://127.0.0.1:1") | access_key_id: nil}

      assert {:error, {:keys_missing, :snapshot_s3_access_key_id}} =
               S3.store(snapshot!(tmp, "bytes"), settings, opts(tmp))
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
      credentials: :access_keys,
      access_key_id: "AKIAINVENTED",
      secret_access_key: "invented-secret"
    }
  end

  defp instance_role(endpoint),
    do: %{
      settings(endpoint)
      | credentials: :instance_role,
        access_key_id: nil,
        secret_access_key: nil
    }

  defp write_session!(dir, expiration, overrides \\ []) do
    fields = %{
      "access_key_id" => "ASIAINVENTEDSESSION",
      "secret_access_key" => "invented-session-secret",
      "session_token" => @session_token,
      "expiration" => DateTime.to_iso8601(expiration),
      "account_id" => Keyword.get(overrides, :account_id, "111122223333")
    }

    File.write!(Path.join(dir, "credentials.json"), Jason.encode!(fields))
  end

  defp opts, do: [profile: "general", now: fn -> @now end]
  defp opts(session_dir), do: [{:session_dir, session_dir} | opts()]

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

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end
