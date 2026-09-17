defmodule FermixCore.Providers.ErrorTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.Failover
  alias FermixCore.Providers.Transient

  @no_reason "The response body was empty, so the provider gave no reason for this status."

  describe "api/5 when the body carries no reason" do
    # Codex answered the first call of a cron run with HTTP 404 and a zero-byte
    # body (2026-09-15). That decoded to a message of "" rather than nil, so the
    # "HTTP <status>" floor never applied: the operator was told to check logs
    # that read `404 - ""`, and an agent asked about the failure filled the
    # silence with a guess about an unavailable model.
    for body <- ["", "   \n"] do
      test "a blank body #{inspect(body)} says the provider gave no reason" do
        {:provider_error, error} =
          ProviderError.api(:openai_codex, :codex, 404, unquote(body))

        assert error.message == @no_reason
        assert error.status == 404
      end
    end

    test "saying so leaves the classification exactly as it was" do
      reason = ProviderError.api(:openai_codex, :codex, 404, "")
      {:provider_error, error} = reason

      assert error.kind == :provider
      refute Transient.retryable?(reason)
      refute Failover.eligible?(reason)
    end

    test "a JSON message that is blank reports the status, not an empty string" do
      {:provider_error, error} =
        ProviderError.api(:openai_codex, :codex, 404, %{"error" => %{"message" => ""}})

      assert error.message == "HTTP 404"
    end
  end

  describe "api/5 when the body carries a reason" do
    test "the provider's own message is reported unchanged" do
      {:provider_error, error} =
        ProviderError.api(:openai_codex, :codex, 404, %{
          "error" => %{"message" => "Model not found"}
        })

      assert error.message == "Model not found"
    end

    test "a JSON body without any message still reports the status" do
      {:provider_error, error} = ProviderError.api(:openai_codex, :codex, 404, %{})

      assert error.message == "HTTP 404"
    end
  end
end
