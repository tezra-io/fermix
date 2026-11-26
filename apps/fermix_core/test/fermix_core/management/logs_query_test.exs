defmodule FermixCore.Management.LogsQueryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Logs
  alias FermixTestSupport.SafeRm

  # The tail each file is read to (`@max_file_scan_bytes` in Logs).
  @max_file_scan_bytes 2_097_152

  setup do
    dir = SafeRm.make_tmp_dir!("management_logs")
    on_exit(fn -> SafeRm.rm_rf!(dir) end)
    %{dir: dir, log: Path.join(dir, "fermix.log")}
  end

  test "defaults to a 200 entry tail and refuses a request above 500", %{log: log} do
    write_log(log, for(index <- 1..260, do: line(index, "info", "plugins", "entry #{index}")))

    assert {:ok, result} = Logs.query(%{}, log_file: log)
    assert result["count"] == 200
    assert length(result["entries"]) == 200
    assert List.first(result["entries"])["message"] == "[plugins] entry 61"
    assert List.last(result["entries"])["message"] == "[plugins] entry 260"
    assert result["direction"] == "backward"

    assert {:ok, capped} = Logs.query(%{"limit" => 500}, log_file: log)
    assert capped["count"] == 260

    assert {:error, :invalid_params} = Logs.query(%{"limit" => 501}, log_file: log)
    assert {:error, :invalid_params} = Logs.query(%{"limit" => 0}, log_file: log)
  end

  test "reads the rotated set newest first", %{log: log} do
    write_log(log <> ".1", [line(1, "info", "boot", "oldest")])
    write_log(log <> ".0", [line(2, "info", "boot", "middle")])
    write_log(log, [line(3, "info", "boot", "newest")])

    assert {:ok, result} = Logs.query(%{"limit" => 10}, log_file: log)

    assert Enum.map(result["entries"], & &1["message"]) == [
             "[boot] oldest",
             "[boot] middle",
             "[boot] newest"
           ]
  end

  # `:logger_std_h` with `max_no_files: N` keeps archives `.0` … `.(N-1)`, so a
  # reader that stops at `.(N-2)` hides the oldest retained file entirely and
  # reports its absence as the honest end of the set.
  test "scans every archive the handler retains for the configured depth", %{log: log} do
    write_log(log <> ".2", [line(1, "info", "boot", "too old")])
    write_log(log <> ".1", [line(2, "info", "boot", "oldest kept")])
    write_log(log <> ".0", [line(3, "info", "boot", "kept")])
    write_log(log, [line(4, "info", "boot", "newest")])

    assert {:ok, result} = Logs.query(%{"limit" => 10}, log_file: log, max_no_files: 2)

    assert Enum.map(result["entries"], & &1["message"]) == [
             "[boot] oldest kept",
             "[boot] kept",
             "[boot] newest"
           ]
  end

  # One rotation policy, one resolver. The handler and this reader must agree on
  # how many archives exist, or the reader silently truncates the retained set.
  test "reads the same rotation depth the log handler installs" do
    assert FermixCore.Application.log_max_no_files() ==
             Application.get_env(:fermix_core, :log, []) |> Keyword.fetch!(:max_no_files)
  end

  # An unreadable file is not an empty one. Collapsing EACCES into `count: 0`
  # is indistinguishable from "the daemon has written nothing", which the module
  # documents as a normal state.
  test "an unreadable log file is reported, not rendered as an empty page", %{log: log} do
    write_log(log, [line(1, "info", "boot", "entry")])
    File.chmod!(log, 0o000)
    on_exit(fn -> File.chmod(log, 0o600) end)

    assert {:error, :unreadable} = Logs.query(%{}, log_file: log)
  end

  # The per-entry bound is published in bytes; truncating by graphemes returns
  # up to four times it on multi-byte text.
  test "the per-entry message bound is enforced in bytes", %{log: log} do
    wide = String.duplicate("漢", 4_000)
    write_log(log, [line(1, "info", "boot", wide)])

    assert {:ok, %{"entries" => [entry]}} = Logs.query(%{}, log_file: log)
    assert byte_size(entry["message"]) <= 4_096 + byte_size("…")
    assert String.valid?(entry["message"])
    assert String.ends_with?(entry["message"], "…")
  end

  test "filters by minimum level, subsystem, and case-insensitive search", %{log: log} do
    write_log(log, [
      line(1, "debug", "plugins", "catalog parsed"),
      line(2, "info", "plugins", "Catalog Loaded"),
      line(3, "error", "daemon", "socket refused")
    ])

    assert {:ok, %{"entries" => entries}} = Logs.query(%{"level" => "info"}, log_file: log)
    assert Enum.map(entries, & &1["level"]) == ["info", "error"]

    assert {:ok, %{"entries" => entries}} = Logs.query(%{"subsystem" => "plugins"}, log_file: log)
    assert Enum.map(entries, & &1["subsystem"]) == ["plugins", "plugins"]

    assert {:ok, %{"entries" => entries}} = Logs.query(%{"search" => "catalog"}, log_file: log)
    assert length(entries) == 2

    assert {:error, :invalid_params} =
             Logs.query(%{"search" => String.duplicate("x", 257)}, log_file: log)

    assert {:error, :invalid_params} = Logs.query(%{"direction" => "sideways"}, log_file: log)
    assert {:error, :invalid_params} = Logs.query(%{"level" => "chatty"}, log_file: log)
  end

  test "an opaque cursor pages older entries and reverses forward", %{log: log} do
    write_log(log, for(index <- 1..10, do: line(index, "info", "boot", "entry #{index}")))

    assert {:ok, page1} = Logs.query(%{"limit" => 4}, log_file: log)
    page1_messages = Enum.map(page1["entries"], & &1["message"])

    assert page1_messages == [
             "[boot] entry 7",
             "[boot] entry 8",
             "[boot] entry 9",
             "[boot] entry 10"
           ]

    assert is_binary(page1["cursor"])
    refute page1["cursor"] =~ "entry"

    assert {:ok, page2} = Logs.query(%{"limit" => 4, "cursor" => page1["cursor"]}, log_file: log)

    assert Enum.map(page2["entries"], & &1["message"]) == [
             "[boot] entry 3",
             "[boot] entry 4",
             "[boot] entry 5",
             "[boot] entry 6"
           ]

    assert {:ok, forward} =
             Logs.query(
               %{"limit" => 2, "direction" => "forward", "cursor" => page2["cursor"]},
               log_file: log
             )

    assert Enum.map(forward["entries"], & &1["message"]) == ["[boot] entry 3", "[boot] entry 4"]
  end

  test "a cursor issued before rotation expires explicitly", %{log: log} do
    write_log(log <> ".0", [line(1, "info", "boot", "archived")])
    write_log(log, for(index <- 2..8, do: line(index, "info", "boot", "entry #{index}")))

    assert {:ok, page1} = Logs.query(%{"limit" => 3}, log_file: log)
    assert is_binary(page1["cursor"])

    rotate(log)

    assert {:error, :cursor_expired} =
             Logs.query(%{"limit" => 3, "cursor" => page1["cursor"]}, log_file: log)

    assert {:error, :invalid_params} = Logs.query(%{"cursor" => "not-a-cursor"}, log_file: log)
  end

  test "the encoded result is capped and reports truncation", %{log: log} do
    fat = String.duplicate("y", 3_000)
    write_log(log, for(index <- 1..500, do: line(index, "info", "boot", "#{index} #{fat}")))

    assert {:ok, result} = Logs.query(%{"limit" => 500}, log_file: log)

    assert result["truncated"] == true
    assert result["count"] < 500
    assert byte_size(Jason.encode!(result["entries"])) <= 262_144
  end

  test "redaction runs again on the returned entries", %{log: log} do
    write_log(log, [
      line(1, "error", "providers", "auth failed with sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    ])

    assert {:ok, %{"entries" => [entry]}} = Logs.query(%{}, log_file: log)
    refute entry["message"] =~ "sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
    assert entry["message"] =~ "[REDACTED:openai]"
  end

  test "a continuation line joins its entry rather than becoming one", %{log: log} do
    write_log(log, [
      line(1, "error", "daemon", "crash report"),
      "    ** (RuntimeError) boom",
      "        lib/thing.ex:12",
      line(2, "info", "daemon", "recovered")
    ])

    assert {:ok, %{"entries" => entries}} = Logs.query(%{}, log_file: log)
    assert length(entries) == 2
    assert Enum.at(entries, 0)["message"] =~ "** (RuntimeError) boom"
    assert Enum.at(entries, 1)["message"] == "[daemon] recovered"
  end

  # Not every byte in the live log is valid UTF-8. The daemon's console handler
  # flattens its own chardata bytewise, so `\u00b5` reaches the file as the bare byte
  # 0xB5 (Phoenix writes "connected in 872\u00b5s" on every LiveView mount). One such
  # byte made `Jason.encode!` raise inside the page cap, the router answered
  # `internal_error`, and the whole pane went empty for a line the operator can
  # still read.
  test "a line with an invalid UTF-8 byte is delivered rather than raised on", %{log: log} do
    File.write!(log, [
      line(1, "info", "web", "connected in 872"),
      <<0xB5>>,
      "s\n",
      "  12:43:18.337 [info] replied in 58",
      <<0xB5>>,
      "s\n",
      line(2, "info", "web", "ready"),
      "\n"
    ])

    assert {:ok, %{"entries" => entries}} = Logs.query(%{}, log_file: log)
    assert length(entries) == 2

    assert Enum.at(entries, 0)["message"] =~ "connected in 872\uFFFDs"
    assert Enum.at(entries, 0)["message"] =~ "replied in 58\uFFFDs"
    assert Enum.at(entries, 1)["message"] == "[web] ready"
    assert Enum.all?(entries, &String.valid?(&1["message"]))
    assert is_binary(Jason.encode!(entries))
  end

  test "a missing log set returns an empty page, not an error", %{dir: dir} do
    assert {:ok, result} = Logs.query(%{}, log_file: Path.join(dir, "absent.log"))
    assert result["entries"] == []
    assert result["count"] == 0
    assert result["cursor"] == nil
  end

  describe "a page formats only the entries it gathers" do
    test "each page of a dense log is the page its entries give", %{log: log} do
      write_log(log, Enum.flat_map(1..30, &dense_lines/1))

      assert {:ok, page1} = Logs.query(%{"limit" => 4}, log_file: log)
      assert_page(page1, dense(27..30), 4)

      assert {:ok, page2} =
               Logs.query(%{"limit" => 4, "cursor" => page1["cursor"]}, log_file: log)

      assert_page(page2, dense(23..26), 8)

      assert {:ok, forward} =
               Logs.query(
                 %{"limit" => 2, "direction" => "forward", "cursor" => page2["cursor"]},
                 log_file: log
               )

      assert_page(forward, dense(23..24), 6, "forward")

      assert {:ok, newest} =
               Logs.query(
                 %{"limit" => 4, "direction" => "forward", "cursor" => page1["cursor"]},
                 log_file: log
               )

      assert_page(newest, dense(27..30), nil, "forward")

      assert {:ok, unmatched} = Logs.query(%{"search" => "absent"}, log_file: log)
      assert_page(unmatched, [], nil)
      assert {:ok, no_errors} = Logs.query(%{"level" => "error"}, log_file: log)
      assert_page(no_errors, [], nil)

      assert {:ok, warnings} = Logs.query(%{"level" => "warning", "limit" => 3}, log_file: log)
      assert_page(warnings, dense([24, 27, 30]), 3)

      assert {:ok, older_warnings} =
               Logs.query(
                 %{"level" => "warning", "limit" => 3, "cursor" => warnings["cursor"]},
                 log_file: log
               )

      assert_page(older_warnings, dense([15, 18, 21]), 6)

      # Six entries carry a continuation line. A page of exactly six is the end
      # of the set: no extra match exists, so no cursor is offered.
      assert {:ok, details} = Logs.query(%{"search" => "DETAIL OF", "limit" => 6}, log_file: log)
      assert_page(details, dense([5, 10, 15, 20, 25, 30]), nil)
      assert {:ok, fewer} = Logs.query(%{"search" => "detail of", "limit" => 5}, log_file: log)
      assert_page(fewer, dense([10, 15, 20, 25, 30]), 5)
    end

    test "a search whose only matches are the oldest entries still finds them", %{log: log} do
      needles = [line(1, "info", "boot", "needle one"), line(2, "info", "boot", "needle two")]
      write_log(log <> ".1", needles ++ for(index <- 3..400, do: hay(index)))
      write_log(log <> ".0", for(index <- 401..800, do: hay(index)))
      write_log(log, for(index <- 801..1_200, do: hay(index)))
      one = entry(1, "info", "boot", "needle one")
      two = entry(2, "info", "boot", "needle two")

      assert {:ok, found} = Logs.query(%{"search" => "needle"}, log_file: log)
      assert_page(found, [one, two], nil)

      assert {:ok, newest} = Logs.query(%{"search" => "needle", "limit" => 1}, log_file: log)
      assert_page(newest, [two], 1)

      assert {:ok, oldest} =
               Logs.query(
                 %{"search" => "needle", "limit" => 1, "cursor" => newest["cursor"]},
                 log_file: log
               )

      assert_page(oldest, [one], nil)
    end

    test "a secret on a continuation line is redacted, and a search never matches it",
         %{log: log} do
      write_log(log, [
        line(1, "error", "tls", "loaded -----BEGIN PRIVATE KEY-----"),
        "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC",
        "-----END PRIVATE KEY-----",
        line(2, "error", "providers", "request failed"),
        "    authorization: sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345",
        line(3, "info", "daemon", "recovered")
      ])

      key = entry(1, "error", "tls", "loaded [REDACTED:private-key]")

      token =
        entry(2, "error", "providers", "request failed\n    authorization: [REDACTED:openai]")

      assert {:ok, page} = Logs.query(%{}, log_file: log)
      assert_page(page, [key, token, entry(3, "info", "daemon", "recovered")], nil)

      for secret <- ["MIIEvQIBADANBgkq", "BEGIN PRIVATE KEY", "sk-ABCDEFGH", "UVWXYZ012345"] do
        assert {:ok, unmatched} = Logs.query(%{"search" => secret}, log_file: log)
        assert_page(unmatched, [], nil)
      end

      assert {:ok, marked} = Logs.query(%{"search" => "[REDACTED:"}, log_file: log)
      assert_page(marked, [key, token], nil)
    end

    test "a search reads a line's repaired text, never its invalid bytes", %{log: log} do
      File.write!(log, [
        line(1, "info", "web", "connected in 872"),
        <<0xB5>>,
        "s\n",
        line(2, "info", "web", "ready"),
        "\n"
      ])

      repaired = entry(1, "info", "web", "connected in 872�s")

      assert {:ok, found} = Logs.query(%{"search" => "872�s"}, log_file: log)
      assert_page(found, [repaired], nil)
      assert is_binary(Jason.encode!(found))

      assert {:ok, newest} = Logs.query(%{"limit" => 1}, log_file: log)
      assert_page(newest, [entry(2, "info", "web", "ready")], 1)

      assert {:ok, older} =
               Logs.query(%{"limit" => 1, "cursor" => newest["cursor"]}, log_file: log)

      assert_page(older, [repaired], nil)
    end

    # Each file is read to its last 2 MiB. A tail that starts mid-line starts
    # with a fragment, and a fragment cut inside the timestamp parses as an
    # entry with a broken time, so it must be dropped, not delivered.
    test "a file over the scan bound drops the line the bound cuts", %{log: log} do
      write_log(log, for(index <- 1..11_000, do: bulk_line(index)))
      width = byte_size(bulk_line(1)) + 1
      offset = File.stat!(log).size - @max_file_scan_bytes
      cut = div(offset, width) + 1
      # The fixture's own check: the bound lands inside the cut line's timestamp.
      assert rem(offset, width) in 1..25

      assert {:ok, dropped} = Logs.query(%{"search" => "row-#{pad(cut)}."}, log_file: log)
      assert_page(dropped, [], nil)

      assert {:ok, first} = Logs.query(%{"search" => "row-#{pad(cut + 1)}."}, log_file: log)
      assert_page(first, [bulk_entry(cut + 1)], nil)

      assert {:ok, newest} = Logs.query(%{"limit" => 2}, log_file: log)
      assert_page(newest, [bulk_entry(10_999), bulk_entry(11_000)], 2)
    end

    test "a page spans two rotated files, and rotating the set expires its cursor",
         %{log: log} do
      write_log(
        log <> ".0",
        for(index <- 1..6, do: line(index, "info", "boot", "entry #{index}"))
      )

      write_log(log, for(index <- 7..9, do: line(index, "info", "boot", "entry #{index}")))

      assert {:ok, page1} = Logs.query(%{"limit" => 5}, log_file: log)
      assert_page(page1, boot(5..9), 5)

      assert {:ok, page2} =
               Logs.query(%{"limit" => 5, "cursor" => page1["cursor"]}, log_file: log)

      assert_page(page2, boot(1..4), nil)

      # The live file holds exactly this page: the extra match that offers a
      # cursor is the archive's newest entry.
      assert {:ok, live} = Logs.query(%{"limit" => 3}, log_file: log)
      assert_page(live, boot(7..9), 3)

      rotate(log)

      assert {:error, :cursor_expired} =
               Logs.query(%{"limit" => 5, "cursor" => page1["cursor"]}, log_file: log)

      assert {:ok, rotated} = Logs.query(%{"limit" => 5}, log_file: log)
      assert_page(rotated, boot(5..9), 5)
    end

    test "an unreadable archive fails the page that reaches it, not one the live file fills",
         %{log: log} do
      write_log(log <> ".0", [line(1, "info", "boot", "entry 1")])
      write_log(log, [line(2, "info", "boot", "entry 2"), line(3, "info", "boot", "entry 3")])
      File.chmod!(log <> ".0", 0o000)
      on_exit(fn -> File.chmod(log <> ".0", 0o600) end)

      assert {:ok, filled} = Logs.query(%{"limit" => 1}, log_file: log)
      assert_page(filled, boot(3..3), 1)

      assert {:error, :unreadable} = Logs.query(%{"limit" => 2}, log_file: log)
    end

    test "the byte cap keeps the newest entries, and the cursor resumes below them",
         %{log: log} do
      fat = String.duplicate("y", 3_000)
      write_log(log, for(index <- 1..120, do: line(index, "info", "boot", "#{index} #{fat}")))
      fat_entry = &entry(&1, "info", "boot", "#{&1} #{fat}")

      assert {:ok, capped} = Logs.query(%{"limit" => 120}, log_file: log)
      count = capped["count"]
      assert count in 1..119
      assert capped["truncated"] == true
      assert capped["entries"] == Enum.map((121 - count)..120, fat_entry)
      assert anchor(capped) == count
      assert byte_size(Jason.encode!(capped["entries"])) <= 262_144
      # The cap counts one byte the array never spends, so the next older entry
      # was left out because it would have brought the page to the cap or over.
      next_older = fat_entry.(120 - count)
      assert byte_size(Jason.encode!([next_older | capped["entries"]])) >= 262_144

      assert {:ok, rest} =
               Logs.query(%{"limit" => 120, "cursor" => capped["cursor"]}, log_file: log)

      assert List.last(rest["entries"]) == next_older
    end

    # Reductions count the work this process did, whatever else the machine is
    # running, so the bound holds without a clock. A search that matches
    # nothing must format every entry in the tail; the default page needs 201
    # matches of 4,000 and must stop there.
    test "the default page formats a page's worth of entries, not the whole tail",
         %{log: log} do
      write_log(log, for(index <- 1..4_000, do: bulk_line(index)))

      first_page = reductions(fn -> Logs.query(%{}, log_file: log) end)
      full_scan = reductions(fn -> Logs.query(%{"search" => "absent"}, log_file: log) end)

      assert first_page * 3 < full_scan,
             "the first page cost #{first_page} reductions, a full scan #{full_scan}"
    end
  end

  defp assert_page(result, entries, anchor, direction \\ "backward") do
    assert Map.delete(result, "cursor") == %{
             "entries" => entries,
             "count" => length(entries),
             "truncated" => false,
             "direction" => direction
           }

    assert anchor(result) == anchor
  end

  defp anchor(%{"cursor" => nil}), do: nil

  defp anchor(%{"cursor" => cursor}) do
    decoded = cursor |> Base.url_decode64!(padding: false) |> Jason.decode!()
    assert %{"anchor" => anchor, "fingerprint" => fingerprint} = decoded
    assert map_size(decoded) == 2 and is_integer(fingerprint)
    anchor
  end

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    assert {:ok, _result} = fun.()
    {:reductions, after_query} = Process.info(self(), :reductions)
    after_query - before
  end

  # Thirty entries: every third is a warning, every fifth has a continuation line.
  defp dense_lines(index) do
    [line(index, dense_level(index), "dense", "entry #{index}") | dense_detail(index)]
  end

  defp dense(indexes) do
    Enum.map(indexes, fn index ->
      message = Enum.join(["entry #{index}" | dense_detail(index)], "\n")
      entry(index, dense_level(index), "dense", message)
    end)
  end

  defp dense_level(index) when rem(index, 3) == 0, do: "warning"
  defp dense_level(_index), do: "info"

  defp dense_detail(index) when rem(index, 5) == 0, do: ["    detail of entry #{index}"]
  defp dense_detail(_index), do: []

  defp boot(indexes), do: Enum.map(indexes, &entry(&1, "info", "boot", "entry #{&1}"))

  defp hay(index), do: line(index, "info", "boot", "hay #{index}")

  # 202 bytes with its newline, so the 2 MiB bound lands 12 bytes into a line.
  defp bulk_line(index), do: line(index, "info", "bulk", bulk_message(index))
  defp bulk_entry(index), do: entry(index, "info", "bulk", bulk_message(index))
  defp bulk_message(index), do: "row-#{pad(index)}. " <> String.duplicate("z", 150)

  defp pad(index), do: String.pad_leading(Integer.to_string(index), 6, "0")

  defp entry(index, level, subsystem, message) do
    %{
      "time" => stamp(index),
      "level" => level,
      "subsystem" => subsystem,
      "message" => "[#{subsystem}] #{message}"
    }
  end

  defp stamp(index) do
    "2026-08-19T10:00:#{String.pad_leading(Integer.to_string(rem(index, 60)), 2, "0")}.000000"
  end

  defp line(index, level, subsystem, message) do
    "#{stamp(index)} #{level} [#{subsystem}] #{message}"
  end

  defp write_log(path, lines) do
    File.write!(path, Enum.join(lines, "\n") <> "\n")
  end

  defp rotate(log) do
    if File.exists?(log <> ".0"), do: File.rename!(log <> ".0", log <> ".1")
    File.rename!(log, log <> ".0")
    File.write!(log, "")
  end
end
