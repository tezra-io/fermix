defmodule FermixTestSupport.FakeVendorCli do
  @moduledoc """
  Test-only generator for a self-contained `sh` stub that stands in for a vendor
  CLI (`codex` / `claude`) in the coding-harness tests (`Harness.Run`, and later
  `Harness.Manager`).

  `Harness.Run` spawns the vendor binary through `env -i HOME=… PATH=… TERM=… …`
  (`Harness.Env`), which wipes the environment. So — unlike the compux perl
  sidecar, which is parameterized by `FAKE_PROTO` in the environment — every
  behavior flag here is **baked into the generated script as a shell literal**,
  reaching the stub through the `env -i` barrier without any env or argv channel.

  `write!/2` writes the fixture lines and the stub script under `dir` (a SafeRm
  tmp dir the caller owns) and returns the absolute script path. Options:

    * `:lines` — the JSONL lines to replay to stdout, in order (required).
    * `:exit_code` — the process exit code (default `0`).
    * `:hang_after` — emit this many lines then sleep forever (default `nil` =
      never hang; used to drive the stall watchdogs and cancellation).
    * `:delay_seconds` — integer seconds to pause between lines (default `0`).
    * `:result_text` — when set AND the argv carries `-o <path>` (codex), write
      this string to that path, mirroring codex's `-o` result file (default nil).
  """

  @spec write!(String.t(), keyword()) :: String.t()
  def write!(dir, opts) when is_binary(dir) and is_list(opts) do
    lines = Keyword.fetch!(opts, :lines)
    unique = System.unique_integer([:positive])
    fixture_path = Path.join(dir, "fixture-#{unique}.jsonl")
    script_path = Path.join(dir, "stub-#{unique}.sh")

    File.write!(fixture_path, Enum.map_join(lines, "\n", & &1) <> "\n")
    File.write!(script_path, script(fixture_path, opts))
    File.chmod!(script_path, 0o755)
    script_path
  end

  defp script(fixture_path, opts) do
    exit_code = Keyword.get(opts, :exit_code, 0)
    hang_after = Keyword.get(opts, :hang_after)
    delay = Keyword.get(opts, :delay_seconds, 0)
    result_text = Keyword.get(opts, :result_text)

    """
    #!/bin/sh
    # generated fake vendor CLI (test only) — behavior baked as shell literals so
    # it survives the env -i barrier Harness.Run spawns it behind.
    EXIT_CODE=#{exit_code}
    DELAY=#{delay}
    HANG_AFTER=#{sh_int(hang_after)}
    RESULT_TEXT=#{sh_squote(result_text)}
    FIXTURE=#{sh_squote(fixture_path)}

    out=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-o" ] && out="$a"
      prev="$a"
    done

    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      if [ -n "$HANG_AFTER" ] && [ "$count" -gt "$HANG_AFTER" ]; then
        while true; do sleep 1; done
      fi
      printf '%s\\n' "$line"
      [ "$DELAY" -gt 0 ] && sleep "$DELAY"
    done < "$FIXTURE"

    if [ -n "$out" ] && [ -n "$RESULT_TEXT" ]; then
      printf '%s' "$RESULT_TEXT" > "$out"
    fi
    exit "$EXIT_CODE"
    """
  end

  defp sh_int(nil), do: "''"
  defp sh_int(n) when is_integer(n) and n >= 0, do: Integer.to_string(n)

  defp sh_squote(nil), do: "''"

  defp sh_squote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
