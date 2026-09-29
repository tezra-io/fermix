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

  test "a tuple is redacted element by element" do
    reason = {:error, {:http, %{"refresh_token" => "rt-1", "error" => "invalid_grant"}}}

    assert {:error, {:http, %{"refresh_token" => "[REDACTED]", "error" => "invalid_grant"}}} =
             Redaction.redact(reason)
  end

  # A header list or a decoded form is a list of string-keyed pairs: the key
  # names the credential and the value need not look like one.
  test "a string-keyed pair is redacted by its key, as a map entry is" do
    pairs = [
      {"authorization", "Basic dXNlcjpwYXNzd29yZA=="},
      {"refresh_token", "rt_TESTSECRET123456"},
      {"content-type", "application/json"}
    ]

    assert Redaction.redact(pairs) == [
             {"authorization", "[REDACTED]"},
             {"refresh_token", "[REDACTED]"},
             {"content-type", "application/json"}
           ]
  end

  # An atom tag names the failure, not the value after it, so a reason such as
  # `{:secret_store_failed, reason}` keeps the detail an operator needs.
  test "an atom-tagged reason keeps its detail" do
    assert Redaction.redact({:secret_store_failed, :locked}) == {:secret_store_failed, :locked}
  end

  # A JSON parse error keeps the whole input it failed on. For auth.json that is
  # every stored token, and the token values are not token-shaped words, so only
  # dropping the input keeps them out of the formatted error.
  test "a JSON parse error loses the input it failed on and keeps its position" do
    error = %Jason.DecodeError{position: 3, data: ~s({"refresh_token":"rt_TESTSECRET123456"})}

    for value <- [error, {:invalid_json, error}] do
      formatted = Redaction.format(value)

      refute formatted =~ "rt_TESTSECRET123456"
      assert formatted =~ "position: 3"
    end
  end
end
