defmodule FermixCore.Computers.OutcomeTest do
  # M97 §6.1, §6.3: how an invocation ended, on the wire and as the model
  # reads it.
  use ExUnit.Case, async: true

  alias FermixCore.Computers.Outcome
  alias FermixCore.Management.Copy

  @at ~U[2031-06-01 09:00:00.120Z]
  @receipt %{at: @at, target: "drafts/plan.txt"}

  defp wire(outcome), do: outcome |> Outcome.to_wire()

  defp round_trip(outcome) do
    {fields, payload} = wire(outcome)
    Outcome.from_wire(fields, payload)
  end

  describe "the wire" do
    test "every status and every refusal goes out and comes back the same" do
      base = %Outcome{status: :ok, invocation: "inv-4k2m", duration_ms: 31, receipt: @receipt}

      outcomes =
        [
          %{base | result: %{"text" => "hello"}},
          %{base | status: :failed, message: "No such file."},
          %{base | status: :timed_out},
          %{base | status: :cancelled},
          %{base | status: :unknown},
          %{base | status: :unknown, message: "Fermix on this computer stopped while it ran."}
        ] ++
          for refusal <- Outcome.refusals(),
              do: %{base | status: :refused, refusal: refusal, message: "Not here."}

      for outcome <- outcomes do
        assert {:ok, back} = round_trip(outcome)
        assert back.status == outcome.status
        assert back.refusal == outcome.refusal
        assert back.message == outcome.message
        assert back.receipt == outcome.receipt
        assert back.result == outcome.result
        assert back.duration_ms == 31
        assert back.invocation == "inv-4k2m"
      end
    end

    test "the closed sets are the design's" do
      assert Outcome.statuses() == [:ok, :failed, :refused, :timed_out, :cancelled, :unknown]

      assert Outcome.refusals() ==
               [
                 :off,
                 :unavailable,
                 :outside_sandbox,
                 :not_attended,
                 :stopped_here,
                 :busy,
                 :stale_epoch
               ]
    end

    test "an answer of the journal's receipt alone carries no result" do
      outcome = %Outcome{status: :ok, invocation: "inv-7", receipt: @receipt, receipt_only: true}
      {fields, payload} = wire(outcome)

      assert payload == ~s({"receipt_only":true})

      assert fields["receipt"] == %{
               "at" => "2031-06-01T09:00:00.120Z",
               "target" => "drafts/plan.txt"
             }

      assert {:ok, %Outcome{receipt_only: true, result: %{}}} = Outcome.from_wire(fields, payload)
    end

    test "a part is announced by its size, its SHA-256 and its type" do
      part = %{size_bytes: 3, sha256: String.duplicate("ab", 32), mime: "image/png"}
      {fields, _payload} = wire(%Outcome{status: :ok, invocation: "inv-8", part: part})

      assert fields["part"] == %{
               "size_bytes" => 3,
               "sha256" => part.sha256,
               "mime" => "image/png"
             }

      assert {:ok, %Outcome{part: ^part}} = Outcome.from_wire(fields, "{}")
    end

    test "a message is one line within its bound, and none rides an ok" do
      long = String.duplicate("é", 400) <> "\nsecond line"
      {fields, _payload} = wire(%Outcome{status: :failed, invocation: "inv-9", message: long})

      assert byte_size(fields["message"]) <= 512
      refute fields["message"] =~ "\n"

      {ok, _payload} = wire(%Outcome{status: :ok, invocation: "inv-9", message: "ignored"})
      refute Map.has_key?(ok, "message")
    end

    test "what the closed sets do not hold is refused by name" do
      ok = %{"id" => "inv-1", "status" => "ok", "duration_ms" => 0}

      assert {:error, {:invalid_field, "status"}} =
               Outcome.from_wire(%{ok | "status" => "done"}, "{}")

      assert {:error, {:invalid_field, "refusal"}} =
               Outcome.from_wire(Map.put(ok, "refusal", "busy"), "{}")

      refused = %{ok | "status" => "refused"} |> Map.put("message", "No.")

      assert {:error, {:invalid_field, "refusal"}} =
               Outcome.from_wire(Map.put(refused, "refusal", "asleep"), "{}")

      assert {:error, {:missing_field, "message"}} =
               Outcome.from_wire(%{ok | "status" => "failed"}, "{}")

      assert {:error, {:invalid_field, "message"}} =
               Outcome.from_wire(Map.put(ok, "message", "Done."), "{}")

      assert {:error, {:invalid_field, "duration_ms"}} =
               Outcome.from_wire(%{ok | "duration_ms" => -1}, "{}")

      assert {:error, {:invalid_result, _why}} = Outcome.from_wire(ok, "[1]")

      assert {:error, {:invalid_field, "receipt"}} =
               Outcome.from_wire(Map.put(ok, "receipt", %{"at" => "noon", "target" => "x"}), "{}")
    end
  end

  describe "what the model is told" do
    test "each status and refusal has a sentence of its own, naming the computer" do
      sentences = Outcome.sentences()

      assert length(Enum.uniq(sentences)) == length(sentences)
      assert Enum.all?(sentences, &(&1 =~ "studio Mac"))
    end

    test "every sentence obeys the copy rules" do
      for sentence <- Outcome.sentences() do
        assert Copy.violations(sentence, :prose, ["studio Mac"]) == [], sentence
      end
    end

    test "an answer that was lost says the outcome is not known, in its own sentence" do
      unknown = %Outcome{status: :unknown, target: "touch drafts/plan.txt"}

      assert Outcome.sentence(unknown, "studio Mac") ==
               "Fermix lost studio Mac's answer, so whether touch drafts/plan.txt happened " <>
                 "is not known. Check before doing it again."
    end

    test "the sentences the plan names read as written" do
      name = "studio Mac"

      assert Outcome.sentence(%{Outcome.refused(:off, "x") | capability: "browser"}, name) ==
               "studio Mac has the browser switched off. Only someone at studio Mac can switch it on."

      assert Outcome.sentence(Outcome.refused(:busy, "x"), name) ==
               "studio Mac is running as much as it allows right now. Try again in a moment."

      assert Outcome.sentence(Outcome.refused(:stale_epoch, "x"), name) ==
               "studio Mac refused a request from an older copy of this Fermix."

      assert Outcome.sentence(Outcome.refused(:stopped_here, "x"), name) ==
               "The person at studio Mac stopped it."

      assert Outcome.sentence(%Outcome{status: :timed_out, deadline_ms: 20_000}, name) ==
               "studio Mac did not finish within 20 seconds."

      assert Outcome.sentence(%Outcome{status: :cancelled}, name) ==
               "Cancelled before studio Mac finished it."

      assert Outcome.sentence(Outcome.refused(:unavailable, "Messages runs only on a Mac."), name) ==
               "Messages runs only on a Mac."
    end
  end

  test "the server's exec row carries ids and closed words, never content" do
    outcome = %Outcome{
      status: :refused,
      refusal: :off,
      message: "Switched off on this Mac.",
      result: %{"secret" => "x"},
      invocation: "inv-3",
      computer: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
      target: "drafts/plan.txt"
    }

    assert Outcome.exec_metadata(outcome) == %{
             computer: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
             invocation: "inv-3",
             invoke_status: :refused,
             refusal: :off
           }

    assert Outcome.exec_metadata(%Outcome{status: :ok, invocation: "inv-4"}) ==
             %{invocation: "inv-4", invoke_status: :ok}
  end
end
