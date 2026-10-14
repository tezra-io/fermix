defmodule FermixCore.Setup.ProviderHealthTest do
  use ExUnit.Case, async: true

  alias FermixCore.Setup.ProviderHealth
  alias FermixTestSupport.SafeRm

  @now ~U[2026-10-14 03:00:00Z]
  @cloudflare_page "../../fixtures/providers/cloudflare_520.html"
                   |> Path.expand(__DIR__)
                   |> File.read!()

  defp row(minutes_ago, fields \\ %{}) do
    Map.merge(
      %{
        "type" => "llm_call",
        "provider" => "openai_codex",
        "adapter" => "chatgpt_plan",
        "status" => "ok",
        "ts" => @now |> DateTime.add(-minutes_ago * 60) |> DateTime.to_iso8601()
      },
      fields
    )
  end

  @cloudflare_sentence "HTTP 520 from Cloudflare in front of the provider, " <>
                         "with an HTML error page instead of an API answer"

  # A turn that met Cloudflare's 520, as the trace records it now: its error is
  # the one sentence `Providers.Error` renders for the page.
  defp failed_turn(minutes_ago) do
    row(minutes_ago, %{
      "status" => "error",
      "error_kind" => "provider_unavailable",
      "error_status" => 520,
      "error" => @cloudflare_sentence
    })
  end

  defp failed_listing(minutes_ago) do
    row(minutes_ago, %{
      "adapter" => "model_listing",
      "status" => "error",
      "error" => "HTTP 520 from https://api.openai.com/v1/models"
    })
  end

  defp write_day(dir, date, lines) do
    day = Path.join(dir, Date.to_iso8601(date))
    File.mkdir_p!(day)
    File.write!(Path.join(day, "llm_call.jsonl"), Enum.map(lines, &[&1, "\n"]))
  end

  defp line(row), do: Jason.encode!(row)

  describe "summarize/3" do
    test "no calls is a pass that says so" do
      assert ProviderHealth.summarize([], :openai_codex, @now) ==
               {:ok, "no calls to OpenAI Codex in the last 24 hours"}
    end

    test "a latest call that succeeded passes and says how long ago" do
      assert {:ok, detail} = ProviderHealth.summarize([row(30), row(3)], :openai_codex, @now)

      assert detail =~ "OpenAI Codex"
      assert detail =~ "3 minutes ago"
      refute detail =~ "failed"
    end

    test "a latest call that succeeded passes and counts the earlier failures" do
      rows = [row(50), failed_turn(40), failed_listing(20), row(10), row(3)]

      assert {:ok, detail} = ProviderHealth.summarize(rows, :openai_codex, @now)
      assert detail =~ "3 minutes ago"
      assert detail =~ "2 of the last 5 failed"
    end

    # One failure can be a blip.
    test "a latest call that failed after an earlier success warns" do
      rows = [row(30), failed_turn(5)]

      assert {:warn, detail} = ProviderHealth.summarize(rows, :openai_codex, @now)
      assert detail =~ "1 of the last 2"
      assert detail =~ "HTTP 520 from Cloudflare"
    end

    test "a single call that failed warns" do
      assert {:warn, detail} = ProviderHealth.summarize([failed_turn(5)], :openai_codex, @now)
      assert detail =~ "only call"
      assert detail =~ "HTTP 520"
    end

    # The owner's incident: four listings and six turns, every one a 520.
    test "every call failing fails, with the count, the span and the latest failure" do
      rows =
        [failed_listing(41), failed_turn(38), failed_turn(30), failed_listing(25)] ++
          [failed_turn(20), failed_listing(15), failed_turn(12), failed_listing(8)] ++
          [failed_turn(6), failed_turn(2)]

      assert {:fail, detail} = ProviderHealth.summarize(rows, :openai_codex, @now)

      assert detail ==
               "OpenAI Codex: all 10 calls in the last 41 minutes failed; the latest got " <>
                 @cloudflare_sentence
    end

    test "calls to another provider are not this provider's" do
      other = row(2, %{"provider" => "anthropic", "status" => "error", "error_status" => 529})

      assert {:ok, "no calls to OpenAI Codex in the last 24 hours"} =
               ProviderHealth.summarize([other], :openai_codex, @now)

      assert {:ok, _detail} = ProviderHealth.summarize([row(10), other], :openai_codex, @now)
    end

    test "calls older than 24 hours are left out" do
      assert {:ok, "no calls to OpenAI Codex in the last 24 hours"} =
               ProviderHealth.summarize([failed_turn(24 * 60 + 1)], :openai_codex, @now)

      rows = [row(24 * 60 + 5), failed_turn(30), failed_turn(10)]
      assert {:fail, detail} = ProviderHealth.summarize(rows, :openai_codex, @now)
      assert detail =~ "all 2 calls in the last 30 minutes"
    end

    test "only the last 20 calls count" do
      rows = [row(200)] ++ Enum.map(100..81//-1, &failed_turn/1)

      assert length(rows) == 21
      assert {:fail, detail} = ProviderHealth.summarize(rows, :openai_codex, @now)
      assert detail =~ "all 20 calls"
    end

    # A refusal of the request itself, a missing adapter, this machine's own
    # connection or proxy, and a probe that never sent anything say nothing
    # about the provider.
    test "failures that are not the provider's are left out" do
      excluded =
        for kind <- ~w(context_length invalid_request not_implemented connection_unavailable
                         proxy_unreachable proxy_refused) do
          row(5, %{"status" => "error", "error_kind" => kind, "error" => "refused"})
        end

      unsent = row(4, %{"status" => "misconfigured", "agent" => "management_job"})

      assert {:ok, detail} =
               ProviderHealth.summarize([row(30)] ++ excluded ++ [unsent], :openai_codex, @now)

      assert detail =~ "30 minutes ago"
      refute detail =~ "failed"
    end

    # A voice note OpenAI refused as an unsupported format says nothing about
    # whether OpenAI answers turns.
    test "image and voice-note calls are not model calls" do
      turn = row(30, %{"provider" => "openai", "adapter" => "responses"})

      voice_note =
        row(4, %{
          "provider" => "openai",
          "adapter" => "openai",
          "purpose" => "transcription",
          "status" => "error",
          "error_code" => "provider_error",
          "error_summary" => "provider_error: HTTP 400: Unsupported file format"
        })

      image = row(2, %{"provider" => "openai", "adapter" => "openai", "status" => "error"})

      assert {:ok, detail} = ProviderHealth.summarize([turn, voice_note, image], :openai, @now)
      assert detail == "the latest call to OpenAI succeeded 30 minutes ago"
    end

    test "a probe's server error and a network error are failures" do
      rows = [
        row(9, %{"status" => "server_error", "agent" => "management_job"}),
        row(4, %{"status" => "network", "agent" => "management_job"})
      ]

      assert {:fail, _detail} = ProviderHealth.summarize(rows, :openai_codex, @now)
    end

    # Rows written before `Providers.Error` rendered pages as one sentence still
    # carry the page.
    test "an old row's HTML page is rendered as the sentence, never quoted" do
      old = row(5, %{"status" => "error", "error_status" => 520, "error" => @cloudflare_page})

      assert {:fail, detail} = ProviderHealth.summarize([old, old], :openai_codex, @now)
      assert detail =~ "the latest got #{@cloudflare_sentence}"
      refute detail =~ "<"
      refute detail =~ "Ray ID"
    end

    test "a failure with no status is named by its kind" do
      timeout =
        row(3, %{
          "status" => "error",
          "error_kind" => "timeout",
          "error" => "Codex transport error: :timeout"
        })

      assert {:warn, detail} = ProviderHealth.summarize([row(30), timeout], :openai_codex, @now)
      assert detail =~ "an error (timeout): Codex transport error: :timeout"
    end
  end

  describe "read/3" do
    setup do
      dir = SafeRm.make_tmp_dir!("provider-health")
      on_exit(fn -> SafeRm.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "a missing trace directory is no calls", %{dir: dir} do
      missing = Path.join(dir, "absent")

      assert ProviderHealth.read(missing, :openai_codex, @now) ==
               {:ok, %{rows: [], undecodable: 0}}
    end

    test "an undecodable line is counted, not dropped silently", %{dir: dir} do
      write_day(dir, ~D[2026-10-14], [line(row(9)), "{\"provider\": \"openai_co", line(row(3))])
      write_day(dir, ~D[2026-10-13], [])

      assert {:ok, %{rows: rows, undecodable: 1}} =
               ProviderHealth.read(dir, :openai_codex, @now)

      assert length(rows) == 2
    end

    # Content capture puts whole prompts in these rows, so a day's file can be
    # large; only its tail is read, and the line the cut lands in is dropped.
    test "a file larger than the cap is read from its tail only", %{dir: dir} do
      padding = String.duplicate("x", 300_000)

      filler =
        for n <- 0..4 do
          line(row(60 - n, %{"provider" => "anthropic", "n" => n, "p" => padding}))
        end

      write_day(dir, ~D[2026-10-14], filler ++ [line(row(3))])
      path = Path.join([dir, "2026-10-14", "llm_call.jsonl"])
      assert File.stat!(path).size > 1_048_576

      assert {:ok, %{rows: rows, undecodable: 0}} = ProviderHealth.read(dir, :openai_codex, @now)

      kept = rows |> Enum.map(& &1["n"]) |> Enum.reject(&is_nil/1)
      refute 0 in kept
      assert 4 in kept
      assert List.last(rows)["provider"] == "openai_codex"
    end

    test "yesterday's file is read when today's has too few calls", %{dir: dir} do
      write_day(dir, ~D[2026-10-14], [line(row(30))])
      write_day(dir, ~D[2026-10-13], [line(row(200)), line(failed_turn(190))])

      assert {:ok, %{rows: rows, undecodable: 0}} = ProviderHealth.read(dir, :openai_codex, @now)
      assert length(rows) == 3
      assert hd(rows)["ts"] == row(200)["ts"]
    end

    test "yesterday's file is not read when today's has enough", %{dir: dir} do
      write_day(dir, ~D[2026-10-14], Enum.map(1..20, &line(row(&1))))
      write_day(dir, ~D[2026-10-13], ["not json"])

      assert {:ok, %{rows: rows, undecodable: 0}} = ProviderHealth.read(dir, :openai_codex, @now)
      assert length(rows) == 20
    end

    test "a read error other than a missing file is returned with its path", %{dir: dir} do
      not_a_dir = Path.join(dir, "traces")
      File.write!(not_a_dir, "")

      assert {:error, {path, :enotdir}} = ProviderHealth.read(not_a_dir, :openai_codex, @now)
      assert path == Path.join([not_a_dir, "2026-10-14", "llm_call.jsonl"])
    end
  end
end
