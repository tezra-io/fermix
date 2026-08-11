defmodule FermixCore.ReplyTest do
  @moduledoc """
  `Reply.format_delivery_error/1` renders every shape of the closed delivery
  vocabulary (M30 §11.3) as an operator sentence — never a raw `inspect`.
  """
  use ExUnit.Case, async: true

  alias FermixCore.Reply

  describe "format_delivery_error/1 — existing channel egress errors" do
    test "keeps the byte and rate-limit wording" do
      assert Reply.format_delivery_error({:byte_cap_exceeded, 2_097_152, 1_048_576}) =~
               "attachment is 2.0 MiB"

      assert Reply.format_delivery_error({:rate_limited, 2_000}) =~ "rate limited"
      assert Reply.format_delivery_error({:rate_limited, 2_000}) =~ "2s"
    end
  end

  describe "format_delivery_error/1 — M30 delivery vocabulary" do
    test "an HTTP status names the status" do
      rendered = Reply.format_delivery_error({:http_status, 502})

      assert rendered =~ "502"
      refute rendered == inspect({:http_status, 502})
    end

    test "every permanent kind gets its own sentence" do
      kinds = [
        :authentication,
        :authorization,
        :invalid_destination,
        :malformed_request,
        :remote_rejected,
        :adapter_unavailable
      ]

      rendered = Enum.map(kinds, &Reply.format_delivery_error({:permanent, &1}))

      for {kind, sentence} <- Enum.zip(kinds, rendered) do
        refute sentence == inspect({:permanent, kind}),
               "expected {:permanent, #{inspect(kind)}} to render a human sentence"

        refute sentence =~ "{:", "expected no raw tuple in #{inspect(sentence)}"
      end

      assert length(Enum.uniq(rendered)) == length(kinds),
             "each permanent kind needs a distinct sentence, got #{inspect(rendered)}"
    end

    test "every transport kind gets its own sentence" do
      kinds = [
        :pool_unavailable,
        :closed,
        :connection_refused,
        :connection_reset,
        :network_unreachable,
        :timeout
      ]

      rendered = Enum.map(kinds, &Reply.format_delivery_error({:transport, &1}))

      for sentence <- rendered do
        refute sentence =~ "{:", "expected no raw tuple in #{inspect(sentence)}"
      end

      assert length(Enum.uniq(rendered)) == length(kinds),
             "each transport kind needs a distinct sentence, got #{inspect(rendered)}"
    end

    test "the watchdog, crash, and contract-violation reasons read as sentences" do
      assert Reply.format_delivery_error(:delivery_timeout) =~ "timed out"
      assert Reply.format_delivery_error({:delivery_crashed, :worker_crash}) =~ "crashed"

      assert Reply.format_delivery_error({:unexpected_delivery_result, :invalid_contract}) =~
               "unrecognized"
    end

    test "resolution failures name the offending platform and adapter" do
      assert Reply.format_delivery_error({:unsupported_delivery_platform, "cli"}) =~ "cli"

      assert Reply.format_delivery_error({:invalid_delivery_adapter, NoSuchAdapter}) =~
               "NoSuchAdapter"
    end
  end

  describe "format_delivery_error/1 — unknown reasons" do
    test "falls back to inspect so nothing is silently swallowed" do
      assert Reply.format_delivery_error({:something_else, 1}) == inspect({:something_else, 1})
    end
  end
end
