defmodule FermixCore.Auth.RedactionTest do
  use ExUnit.Case, async: true

  alias FermixCore.Auth.Redaction

  # A struct is a map that does not enumerate. The HTTP client's errors are
  # structs, and formatting one used to raise, which turned a ChatGPT sign-in
  # whose token request timed out into a crashed job with no sentence.
  test "formats an error struct as itself" do
    error = %Req.TransportError{reason: :timeout}

    assert Redaction.format(error) == inspect(error)
  end

  test "redacts credential fields inside a struct and keeps its type" do
    response = %Req.Response{
      status: 400,
      headers: %{"authorization" => ["Bearer abc.def"], "content-type" => ["application/json"]},
      body: %{"error" => "invalid_grant", "refresh_token" => "rt-1"}
    }

    assert %Req.Response{} = redacted = Redaction.redact(response)
    assert redacted.status == 400
    assert redacted.headers["authorization"] == "[REDACTED]"
    assert redacted.headers["content-type"] == ["application/json"]
    assert redacted.body == %{"error" => "invalid_grant", "refresh_token" => "[REDACTED]"}
  end

  test "a struct inside a tuple's map is redacted too" do
    reason = %{attempt: %Req.Response{status: 401, body: "Bearer abc.def"}}

    assert %{attempt: %Req.Response{body: "Bearer [REDACTED]"}} = Redaction.redact(reason)
  end
end
