defmodule FermixCore.Management.LogsQueryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Management.Logs
  alias FermixTestSupport.SafeRm

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

  test "a missing log set returns an empty page, not an error", %{dir: dir} do
    assert {:ok, result} = Logs.query(%{}, log_file: Path.join(dir, "absent.log"))
    assert result["entries"] == []
    assert result["count"] == 0
    assert result["cursor"] == nil
  end

  defp line(index, level, subsystem, message) do
    stamp =
      "2026-08-19T10:00:#{String.pad_leading(Integer.to_string(rem(index, 60)), 2, "0")}.000000"

    "#{stamp} #{level} [#{subsystem}] #{message}"
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
