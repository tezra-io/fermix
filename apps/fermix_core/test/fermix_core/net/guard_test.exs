defmodule FermixCore.Net.GuardTest do
  use ExUnit.Case, async: true

  alias FermixCore.Net.Guard

  test "allows public http and https hosts after DNS preflight" do
    resolver = fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end

    assert :ok = Guard.validate("https://example.com/path", resolver: resolver)
    assert :ok = Guard.validate("http://example.com/path", resolver: resolver)
  end

  test "rejects non-http schemes, whitespace, localhost, and local domains" do
    assert {:error, :scheme_not_http_or_https} = Guard.validate("file:///etc/passwd")
    assert {:error, :url_has_whitespace} = Guard.validate("https://example.com/a b")
    assert {:error, {:blocked_host, :localhost}} = Guard.validate("http://localhost:4000")
    assert {:error, {:blocked_host, :local_domain}} = Guard.validate("http://printer.local")
  end

  test "blocks private IP literals and IPv4-mapped IPv6 literals" do
    assert {:error, {:blocked_host, :private_address}} =
             Guard.validate("http://169.254.169.254/latest/meta-data")

    assert {:error, {:blocked_host, :private_address}} =
             Guard.validate("http://[::ffff:127.0.0.1]/")
  end

  test "blocks DNS answers that resolve to private addresses" do
    resolver = fn "safe-looking.example" -> {:ok, [{169, 254, 169, 254}]} end

    assert {:error, {:resolved_to_private_address, {169, 254, 169, 254}}} =
             Guard.validate("https://safe-looking.example", resolver: resolver)
  end

  test "validates redirect targets with the same rules" do
    resolver = fn
      "example.com" -> {:ok, [{93, 184, 216, 34}]}
      "localhost" -> {:ok, [{127, 0, 0, 1}]}
    end

    assert {:error, {:blocked_host, :localhost}} =
             Guard.validate_redirect("http://localhost/private", "https://example.com",
               resolver: resolver
             )
  end

  test "redacts sensitive headers case-insensitively" do
    headers = [
      {"Authorization", "Bearer abc"},
      {"cookie", "sid=1"},
      {"x-api-key", "secret"},
      {"X-Subscription-Token", "brave-secret"},
      {"Content-Type", "text/html"}
    ]

    assert Guard.redact_headers(headers) == [
             {"Authorization", "***REDACTED***"},
             {"cookie", "***REDACTED***"},
             {"x-api-key", "***REDACTED***"},
             {"X-Subscription-Token", "***REDACTED***"},
             {"Content-Type", "text/html"}
           ]
  end

  test "redacts headers into a JSON-safe trace shape" do
    headers = %{"Authorization" => "Bearer abc", "Content-Type" => "text/html"}

    assert Guard.redact_headers_for_trace(headers) == [
             %{name: "Authorization", value: "***REDACTED***"},
             %{name: "Content-Type", value: "text/html"}
           ]
  end
end
