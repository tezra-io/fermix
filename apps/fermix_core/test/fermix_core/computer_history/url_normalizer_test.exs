defmodule FermixCore.ComputerHistory.UrlNormalizerTest do
  @moduledoc """
  MILESTONE_32.1 §2.4 / inv. 27 — a stored URL is scheme + host + path, http(s)
  only. Pure; no store, no capture.
  """
  use ExUnit.Case, async: true

  alias FermixCore.ComputerHistory.UrlNormalizer, as: Url

  describe "what survives" do
    test "scheme, host and path are kept; scheme and host are lowercased" do
      assert {:ok, %{url: "https://example.com/A/b", host: "example.com"}} =
               Url.normalize("HTTPS://Example.COM:8443/A/b")
    end

    test "an empty path becomes /" do
      assert {:ok, %{url: "https://example.com/", host: "example.com"}} =
               Url.normalize("https://example.com")
    end

    test "plain http is kept" do
      assert {:ok, %{url: "http://localhost/status", host: "localhost"}} =
               Url.normalize("http://localhost:4000/status")
    end
  end

  describe "what is dropped from the URL" do
    test "the query string and the fragment" do
      assert {:ok, %{url: "https://mail.example.com/u/0/inbox"}} =
               Url.normalize("https://mail.example.com/u/0/inbox?token=abc&v=1#thread-9")
    end

    test "userinfo (a credential) and the port" do
      assert {:ok, %{url: "https://git.example.com/repo", host: "git.example.com"}} =
               Url.normalize("https://alice:s3cret@git.example.com:8443/repo")
    end
  end

  # The recorder sends the CFURL serialization, which is ASCII: a punycoded host and
  # a percent-encoded path. Both must survive verbatim, and a raw non-ASCII URL is a
  # contract violation the parser refuses rather than repairs.
  describe "the ASCII input contract" do
    test "a punycoded host and a percent-encoded path normalize unchanged" do
      assert {:ok,
              %{url: "https://xn--bcher-kva.example/%E6%97%A5", host: "xn--bcher-kva.example"}} =
               Url.normalize("https://xn--bcher-kva.example/%E6%97%A5")
    end

    test "a raw non-ASCII host or path is refused, not repaired" do
      assert Url.normalize("https://bücher.example/x") == :error
      assert Url.normalize("https://example.com/日") == :error
    end
  end

  describe ":error — not a usable page address" do
    test "a non-http scheme" do
      assert Url.normalize("file:///Users/x/secret.txt") == :error
      assert Url.normalize("about:blank") == :error
      assert Url.normalize("mailto:someone@example.com") == :error
      assert Url.normalize("chrome://settings/passwords") == :error
      assert Url.normalize("javascript:alert(1)") == :error
    end

    test "no host" do
      assert Url.normalize("https:///just/a/path") == :error
      assert Url.normalize("example.com/x") == :error
      assert Url.normalize("") == :error
    end

    test "unparsable" do
      assert Url.normalize("http://exa mple.com/x") == :error
      assert Url.normalize("::::") == :error
    end
  end
end
