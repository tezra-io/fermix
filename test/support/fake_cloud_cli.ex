defmodule FermixTestSupport.FakeCloudCli do
  @moduledoc """
  Test-only generator for a self-contained `sh` stub that stands in for the
  `codex` CLI's **cloud** surface (`codex cloud exec` / `codex cloud status`) in
  the coding-harness manager tests.

  The manager spawns the stub through `env -i HOME=… PATH=… TERM=… …`
  (`Harness.Env`), which wipes the environment — so, like `FakeVendorCli`, every
  behavior is **baked into the generated script as a shell literal / on-disk file**
  and reaches the stub without any env or argv channel.

  The stub dispatches on `$2` (the argv is `cloud exec …` / `cloud status …`, so
  `$2` is the subcommand; a query containing the word "status" can never be
  mistaken for the subcommand). `exec` prints the submit output once. `status`
  advances a file-backed counter each call and prints the Nth scripted status
  (clamped to the last), so a single stub drives a whole `pending → … → ready`
  poll cycle across successive manager ticks without any wall-clock coordination.

  `write!/2` writes the fixtures and the stub script under `dir` (a SafeRm tmp dir
  the caller owns) and returns the absolute script path. Options:

    * `:submit_output` — stdout the `exec` invocation prints (required).
    * `:submit_exit` — the `exec` exit code (default `0`).
    * `:submit_hang` — when `true`, `exec` sleeps forever (drives the submit-timeout
      path); ignores `:submit_output`/`:submit_exit` (default `false`).
    * `:statuses` — an ordered list of `{output, exit}` the successive `status`
      calls return (required unless `:submit_hang`); the last entry repeats.
  """

  @spec write!(String.t(), keyword()) :: String.t()
  def write!(dir, opts) when is_binary(dir) and is_list(opts) do
    unique = System.unique_integer([:positive])
    base = Path.join(dir, "cloud-#{unique}")
    File.mkdir_p!(base)

    submit_hang = Keyword.get(opts, :submit_hang, false)
    statuses = Keyword.get(opts, :statuses, [])

    File.write!(Path.join(base, "submit.out"), Keyword.get(opts, :submit_output, ""))
    write_statuses(base, statuses)

    script_path = Path.join(dir, "cloud-stub-#{unique}.sh")

    File.write!(
      script_path,
      script(base, Keyword.get(opts, :submit_exit, 0), length(statuses), submit_hang)
    )

    File.chmod!(script_path, 0o755)
    script_path
  end

  defp write_statuses(base, statuses) do
    statuses
    |> Enum.with_index(1)
    |> Enum.each(fn {{output, exit_code}, index} ->
      File.write!(Path.join(base, "status_#{index}.out"), output)
      File.write!(Path.join(base, "status_#{index}.exit"), Integer.to_string(exit_code))
    end)
  end

  defp script(base, submit_exit, status_count, submit_hang) do
    """
    #!/bin/sh
    # generated fake codex cloud CLI (test only) — behavior baked as shell literals
    # / on-disk files so it survives the env -i barrier the manager spawns it behind.
    BASE=#{sh_squote(base)}
    SUBMIT_EXIT=#{submit_exit}
    STATUS_COUNT=#{status_count}
    SUBMIT_HANG=#{if submit_hang, do: 1, else: 0}
    COUNTER="$BASE/counter"

    sub="$2"

    if [ "$sub" = "exec" ]; then
      if [ "$SUBMIT_HANG" = "1" ]; then
        while true; do sleep 1; done
      fi
      cat "$BASE/submit.out"
      exit "$SUBMIT_EXIT"
    fi

    if [ "$sub" = "status" ]; then
      n=1
      [ -f "$COUNTER" ] && n=$(($(cat "$COUNTER") + 1))
      printf '%s' "$n" > "$COUNTER"
      idx=$n
      [ "$idx" -gt "$STATUS_COUNT" ] && idx=$STATUS_COUNT
      cat "$BASE/status_$idx.out"
      exit "$(cat "$BASE/status_$idx.exit")"
    fi

    echo "Error: unrecognized cloud subcommand" 1>&2
    exit 2
    """
  end

  defp sh_squote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
