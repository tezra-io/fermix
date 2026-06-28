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

  test "Phoenix filters API-key parameters for every provider and search backend" do
    # Setup-page secret fields are all `*_api_key`. The filter word `api_key` must
    # redact them regardless of which form (or none) wraps them, so adding a new
    # provider/backend key never silently leaks into LiveView event logs.
    flat =
      Phoenix.Logger.filter_values(%{
        "openai_api_key" => "sk-openai",
        "xai_api_key" => "xai-secret",
        "firecrawl_api_key" => "fc-secret",
        "exa_api_key" => "exa-secret",
        "brave_api_key" => "brave-secret",
        "parallel_api_key" => "parallel-secret",
        "api_key" => "bare-secret",
        "backend" => "firecrawl"
      })

    for key <- ~w(openai_api_key xai_api_key firecrawl_api_key exa_api_key
                  brave_api_key parallel_api_key api_key) do
      assert flat[key] == "[FILTERED]",
             "expected #{key} to be filtered, got #{inspect(flat[key])}"
    end

    # Non-secret selector stays visible so logs remain useful for debugging.
    assert flat["backend"] == "firecrawl"

    # LiveView delivers these nested under the form name; filter_values recurses.
    nested =
      Phoenix.Logger.filter_values(%{
        "search_form" => %{"backend" => "firecrawl", "firecrawl_api_key" => "fc-secret"},
        "provider_form" => %{"openai_api_key" => "sk-openai"}
      })

    assert nested["search_form"]["firecrawl_api_key"] == "[FILTERED]"
    assert nested["search_form"]["backend"] == "firecrawl"
    assert nested["provider_form"]["openai_api_key"] == "[FILTERED]"
  end
end
