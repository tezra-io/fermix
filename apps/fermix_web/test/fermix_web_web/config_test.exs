defmodule FermixWebWeb.ConfigTest do
  use ExUnit.Case, async: true

  test "Phoenix filters credential-bearing request parameters" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "token" => "setup-secret",
        "t" => "launch-secret",
        "_csrf_token" => "csrf-secret",
        "access_token" => "access-secret",
        "refresh_token" => "refresh-secret",
        "bot_token" => "bot-secret",
        "verify_token" => "verify-secret",
        "safe" => "visible"
      })

    for key <- ~w(token t _csrf_token access_token refresh_token bot_token verify_token) do
      assert filtered[key] == "[FILTERED]"
    end

    assert filtered["safe"] == "visible"
  end
end
