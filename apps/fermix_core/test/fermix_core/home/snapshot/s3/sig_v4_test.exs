defmodule FermixCore.Home.Snapshot.S3.SigV4Test do
  # AWS's published Signature Version 4 vectors: the generic test suite
  # (`aws-sig-v4-test-suite`: AKIDEXAMPLE, us-east-1, service `service`,
  # 20150830T123600Z) and the S3 examples of "Signature Calculations for the
  # Authorization Header: Transferring Payload in a Single Chunk"
  # (AKIAIOSFODNN7EXAMPLE, us-east-1, s3, 20130524T000000Z).
  use ExUnit.Case, async: true

  alias FermixCore.Home.Snapshot.S3.SigV4

  @suite_credentials %{
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
  }
  @suite_scope %{region: "us-east-1", service: "service", now: ~U[2015-08-30 12:36:00Z]}
  @empty_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @s3_credentials %{
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  }
  @s3_scope %{region: "us-east-1", service: "s3", now: ~U[2013-05-24 00:00:00Z]}

  describe "the generic suite" do
    test "get-vanilla" do
      request = suite_request("GET", [])

      assert authorization(request, @suite_credentials, @suite_scope) ==
               "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " <>
                 "SignedHeaders=host;x-amz-date, " <>
                 "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
    end

    test "get-vanilla-query-order-key-case" do
      request = suite_request("GET", [{"Param2", "value2"}, {"Param1", "value1"}])

      assert signature(request, @suite_credentials, @suite_scope) ==
               "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"
    end

    test "post-vanilla" do
      request = suite_request("POST", [])

      assert signature(request, @suite_credentials, @suite_scope) ==
               "5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b"
    end
  end

  describe "the S3 single-chunk examples" do
    test "PUT Object" do
      payload = "Welcome to Amazon S3."
      payload_sha256 = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

      assert payload_sha256 == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"

      request = %{
        method: "PUT",
        path: "/test$file.text",
        query: [],
        headers: [
          {"Host", "examplebucket.s3.amazonaws.com"},
          {"Date", "Fri, 24 May 2013 00:00:00 GMT"},
          {"x-amz-content-sha256", payload_sha256},
          {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
        ],
        payload_sha256: payload_sha256
      }

      assert authorization(request, @s3_credentials, @s3_scope) ==
               "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " <>
                 "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, " <>
                 "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"
    end

    test "GET Object" do
      request = %{
        method: "GET",
        path: "/test.txt",
        query: [],
        headers: [
          {"Host", "examplebucket.s3.amazonaws.com"},
          {"Range", "bytes=0-9"},
          {"x-amz-content-sha256", @empty_sha256}
        ],
        payload_sha256: @empty_sha256
      }

      assert signature(request, @s3_credentials, @s3_scope) ==
               "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    end
  end

  test "a path is encoded once per segment, slashes kept" do
    assert SigV4.encode_path("/fermix/general/20261027T093000Z-e4.fxsnap") ==
             "/fermix/general/20261027T093000Z-e4.fxsnap"

    assert SigV4.encode_path("/a b/c+d/é") == "/a%20b/c%2Bd/%C3%A9"
  end

  defp suite_request(method, query) do
    %{
      method: method,
      path: "/",
      query: query,
      headers: [{"Host", "example.amazonaws.com"}],
      payload_sha256: @empty_sha256
    }
  end

  defp authorization(request, credentials, scope) do
    {"authorization", value} =
      request |> SigV4.sign(credentials, scope) |> List.keyfind("authorization", 0)

    value
  end

  defp signature(request, credentials, scope) do
    [_before, signature] = String.split(authorization(request, credentials, scope), "Signature=")
    signature
  end
end
