defmodule FermixCore.Providers.ErrorTest do
  use ExUnit.Case, async: true

  alias FermixCore.Providers.Error, as: ProviderError
  alias FermixCore.Providers.Failover
  alias FermixCore.Providers.Transient

  @no_reason "The response body was empty, so the provider gave no reason for this status."

  # Every route leaves through the one proxy, so a failed proxy hop is never a
  # reason to sweep the failover chain.
  describe "transport/4 on a failed proxy hop" do
    # The proxy is down or slow: the same condition as a pool with no
    # connection to give, one hop out. Tried again on the same route, by the
    # in-turn retry and by a scheduled run's backoff alike.
    test "an unreachable proxy is retried on the same route and never failed over" do
      error = ProviderError.transport(:openai, :responses, :proxy_unreachable)

      assert {:provider_transport_error, %{kind: :proxy_unreachable}} = error
      assert Transient.retryable?(error)
      assert Transient.connection_unavailable?(error)
      refute Failover.eligible?(error)
    end

    for reason <- [:proxy_auth_required, :proxy_refused, :proxy_needs_https] do
      test "#{reason} is a refusal: asking again changes nothing" do
        error = ProviderError.transport(:openai, :responses, unquote(reason))

        assert {:provider_transport_error, %{kind: :proxy_refused, reason: unquote(reason)}} =
                 error

        refute Transient.retryable?(error)
        refute Transient.connection_unavailable?(error)
        refute Failover.eligible?(error)
      end
    end
  end

  # M57 §8: ChatGPT plan usage names its refusals with stable codes, and the
  # code decides the kind whether it arrives before the stream (its own HTTP
  # status) or inside `response.failed` on an intact 200.
  describe "api/5 on ChatGPT plan usage codes" do
    @plan_codes [
      {"subscription_sharing_usage_limit_exceeded", 429, :quota},
      {"subscription_sharing_usage_unavailable", 503, :provider_unavailable},
      {"subscription_sharing_user_unavailable", 503, :provider_unavailable},
      {"subscription_sharing_user_not_eligible", 403, :plan_not_eligible},
      {"subscription_sharing_v2_client_not_enabled", 403, :plan_not_eligible},
      {"subscription_sharing_unsupported_capability", 400, :invalid_request},
      {"subscription_sharing_route_not_supported", 403, :invalid_request},
      {"subscription_sharing_invalid_user", 401, :auth}
    ]

    for {code, status, kind} <- @plan_codes do
      test "#{code} is #{kind} before the stream and mid-stream alike" do
        body = %{"error" => %{"code" => unquote(code), "message" => "refused"}}

        for http_status <- [unquote(status), 200] do
          assert {:provider_error, %{kind: unquote(kind), code: unquote(code)}} =
                   ProviderError.api(:chatgpt, :chatgpt_plan, http_status, body)
        end
      end
    end

    test "param is kept when the body names one, and absent when it does not" do
      body = %{
        "error" => %{
          "code" => "subscription_sharing_unsupported_capability",
          "message" => "unsupported",
          "param" => "service_tier"
        }
      }

      assert {:provider_error, %{param: "service_tier"}} =
               ProviderError.api(:chatgpt, :chatgpt_plan, 400, body)

      {:provider_error, error} =
        ProviderError.api(:chatgpt, :chatgpt_plan, 400, %{"error" => %{"code" => "x"}})

      refute Map.has_key?(error, :param)
    end

    test "a bare detail body is never read as a code" do
      body = ~s({"detail":"subscription_sharing_user_not_eligible: plan usage is off"})

      assert {:provider_error, %{code: nil, kind: :auth, message: message}} =
               ProviderError.api(:chatgpt, :chatgpt_plan, 403, body,
                 provider_words: "plan usage is off"
               )

      assert message =~ "plan usage is off"
    end

    test "the provider label is ChatGPT" do
      assert ProviderError.provider_label(:chatgpt) == "ChatGPT"
    end
  end

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
