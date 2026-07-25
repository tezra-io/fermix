defmodule FermixCore.Harness.Adapters.CodexCloud do
  @moduledoc """
  Codex cloud rail: `codex cloud exec` / `codex cloud status` (design §5.3).

  This is a **standalone pure module, not a `FermixCore.Harness.Adapter`
  implementation**. The `Adapter` behaviour models a streamed OS process
  (`plan/2` → `terminal?/1` → `extract/1`); the cloud surface is submit + poll,
  so forcing it into that behaviour would be the cross-vendor normalization the
  design forbids (§16.3). Instead this module owns three pure concerns:

    * `submit_argv/2` — validate the schema'd params (`query`, `env_id`,
      `branch`, `attempts`) and render `codex cloud exec …` argv with an
      absolute binary (via `Harness.Vendors`).
    * `parse_submit/2` — the single task-URL success line, plus classification
      of the two pinned failure diagnostics (`Not signed in.` → auth,
      `Error: …` → command failure).
    * `parse_status/2` — the pinned three-line status form
      (`[STATUS] title` / optional `env  •  reltime` / summary), classifying
      the source status enum (`PENDING | READY | APPLIED | ERROR`).

  The forms below are **source-derived from the pinned CLI** (openai/codex,
  Rust, tag `rust-v0.144.4`) — see the fixtures README. The parser matches
  ONLY these forms: any unrecognized status output is a parse failure the caller
  counts toward its poll error budget, never scraped heuristically (Rule 12,
  no scraping fallback). The exit code is deliberately **not** consulted while a
  status line is present (the pinned CLI exits 0 only for `READY` — the exit-code
  trap; classification is output-driven), only surfaced in the parse-failure
  detail when no status line parsed.
  """

  alias FermixCore.Harness.Vendors

  @cli "codex"

  @known_params ~w(query env_id branch attempts)a

  # `--attempts` is clap-capped 1..4 on the pinned CLI; the adapter mirrors the
  # vendor's own bound rather than inventing a wider one.
  @min_attempts 1
  @max_attempts 4

  # The query rides argv (cloud has no local files, so no brief-file spillover).
  # The byte cap defaults to `Harness.Prompt`'s default but is overridable via
  # `opts[:max_query_bytes]` so the manager can pass the configured
  # `prompt_argv_max_kb` and both rails read one cap (no config drift). An
  # oversized query is an honest refusal, never a silent truncation.
  @default_max_query_bytes 200 * 1024

  @task_url_prefix "https://chatgpt.com/codex/tasks/"
  @not_signed_in_prefix "Not signed in."
  @error_prefix "Error: "

  # Status form separators (source-derived, distinct spacing): the env line uses
  # a double-space bullet, the diff summary a single-space bullet.
  @env_separator "  •  "
  @no_diff "no diff"

  @status_line_regex ~r/^\[(PENDING|READY|APPLIED|ERROR)\](?:\s+(.*))?$/
  @diff_summary_regex ~r/^\+(\d+)\/-(\d+) • (\d+) files?$/u

  @type status_state :: :pending | :ready | :applied | :error

  @typedoc """
  The parsed status view. `state` is the source status enum; `raw` carries the
  display fields (title, optional env label/relative time, summary, and the
  structured diff when the summary matched a pinned form).
  """
  @type status :: %{state: status_state(), raw: map()}

  @typedoc """
  Ledger disposition for a status `state`: `:nonterminal` keeps polling; a
  terminal tuple carries the ledger status string, an optional reason atom, and
  an optional delivery note distinguishing collapsed vendor states.
  """
  @type disposition ::
          :nonterminal | {:terminal, String.t(), atom() | nil, String.t() | nil}

  @doc """
  Renders the `codex cloud exec` submit invocation for `params`.

  `params` is `%{query, env_id, branch?, attempts?}`. `query` and `env_id` are
  required non-empty strings; `branch` is an optional non-empty string;
  `attempts` is an optional integer in `#{@min_attempts}..#{@max_attempts}`.
  Unknown keys fail loud. `opts` carries an optional `:find_executable` resolver
  (default `System.find_executable/1`) so tests stay hermetic and an optional
  `:max_query_bytes` cap (default `#{@default_max_query_bytes}`); the binary is
  resolved absolute via `Harness.Vendors` (a miss is `{:error, :cli_unavailable}`).
  """
  @spec submit_argv(map(), keyword()) ::
          {:ok, %{binary: String.t(), argv: [String.t()]}}
          | {:error,
             {:unknown_param, atom()}
             | {:invalid_param, atom()}
             | {:invalid_param, atom(), term()}
             | :query_too_large
             | :cli_unavailable}
  def submit_argv(params, opts \\ []) when is_map(params) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_query_bytes, @default_max_query_bytes)

    with :ok <- reject_unknown(params),
         {:ok, query} <- fetch_query(params, max_bytes),
         {:ok, env_id} <- fetch_required_string(params, :env_id),
         {:ok, branch_args} <- branch_args(params),
         {:ok, attempts_args} <- attempts_args(params),
         {:ok, binary} <- Vendors.binary(@cli, opts) do
      argv =
        ["cloud", "exec", "--env", env_id] ++ branch_args ++ attempts_args ++ [query]

      {:ok, %{binary: binary, argv: argv}}
    end
  end

  @doc """
  Parses the `codex cloud exec` submit output (merged stdout/stderr + exit code).

  Success is the single task-URL line `#{@task_url_prefix}<task_id>`; `task_id`
  is the last path segment. The two pinned failure diagnostics are classified
  first: a `Not signed in.` line → `{:error, :cloud_auth}`; an `Error: …` line →
  `{:error, {:command_failed, detail}}`. Anything else is
  `{:error, {:submit_parse, detail}}` (the exit code lands in the detail).
  """
  @spec parse_submit(String.t(), integer()) ::
          {:ok, %{task_id: String.t(), task_url: String.t()}}
          | {:error,
             :cloud_auth
             | {:command_failed, String.t()}
             | {:submit_parse, String.t()}}
  def parse_submit(stdout, exit_code) when is_binary(stdout) and is_integer(exit_code) do
    lines = split_lines(stdout)

    cond do
      signed_out?(lines) -> {:error, :cloud_auth}
      (detail = error_detail(lines)) != nil -> {:error, {:command_failed, detail}}
      submit_success?(lines, exit_code) -> {:ok, build_submit(hd(lines))}
      true -> {:error, {:submit_parse, parse_detail(stdout, exit_code)}}
    end
  end

  @doc """
  Parses the `codex cloud status` output (merged stdout/stderr + exit code).

  The pinned form is `[STATUS] title` / optional `env  •  reltime` / summary
  (`no diff` or `+A/-D • N file(s)`). A status line decides output-driven — the
  exit code is not consulted while one is present (READY alone exits 0). A
  `Not signed in.` line → `{:error, :cloud_auth}`; an `Error: …` line with no
  status line → `{:error, {:command_failed, detail}}`; unrecognized output →
  `{:error, {:status_parse, detail}}` (the exit code lands in the detail).
  """
  @spec parse_status(String.t(), integer()) ::
          {:ok, status()}
          | {:error,
             :cloud_auth
             | {:command_failed, String.t()}
             | {:status_parse, String.t()}}
  def parse_status(stdout, exit_code) when is_binary(stdout) and is_integer(exit_code) do
    lines = split_lines(stdout)

    cond do
      signed_out?(lines) -> {:error, :cloud_auth}
      (parsed = status_view(lines)) != nil -> {:ok, parsed}
      (detail = error_detail(lines)) != nil -> {:error, {:command_failed, detail}}
      true -> {:error, {:status_parse, parse_detail(stdout, exit_code)}}
    end
  end

  @doc """
  Maps a status `state` to its ledger disposition (§P mapping table).

    * `:pending` → `:nonterminal` (keep polling)
    * `:ready`   → `completed`
    * `:applied` → `completed` (note: the vendor already applied the diff)
    * `:error`   → `failed`/`:cloud_failed` (may collapse a vendor-side cancel)
  """
  @spec ledger_mapping(status_state()) :: disposition()
  def ledger_mapping(:pending), do: :nonterminal
  def ledger_mapping(:ready), do: {:terminal, "completed", nil, nil}

  def ledger_mapping(:applied),
    do:
      {:terminal, "completed", nil,
       "the vendor already applied the diff to the environment branch"}

  def ledger_mapping(:error),
    do:
      {:terminal, "failed", :cloud_failed,
       "vendor task ended in error (the display collapses a vendor-side cancel into error)"}

  # -- submit param validation -------------------------------------------------

  defp reject_unknown(params) do
    case Enum.find(Map.keys(params), &(&1 not in @known_params)) do
      nil -> :ok
      key -> {:error, {:unknown_param, key}}
    end
  end

  defp fetch_query(params, max_bytes) do
    with {:ok, query} <- fetch_required_string(params, :query) do
      if byte_size(query) > max_bytes, do: {:error, :query_too_large}, else: {:ok, query}
    end
  end

  defp fetch_required_string(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _absent_or_empty -> {:error, {:invalid_param, key}}
    end
  end

  defp branch_args(params) do
    case Map.fetch(params, :branch) do
      :error ->
        {:ok, []}

      {:ok, branch} when is_binary(branch) and branch != "" ->
        {:ok, ["--branch", branch]}

      {:ok, _bad} ->
        {:error, {:invalid_param, :branch}}
    end
  end

  defp attempts_args(params) do
    case Map.fetch(params, :attempts) do
      :error ->
        {:ok, []}

      {:ok, n} when is_integer(n) and n >= @min_attempts and n <= @max_attempts ->
        {:ok, ["--attempts", Integer.to_string(n)]}

      {:ok, bad} ->
        {:error, {:invalid_param, :attempts, bad}}
    end
  end

  # -- submit output parsing ---------------------------------------------------

  # §P: submit success is EXACTLY ONE line — the task URL — with exit 0. A URL
  # accompanied by any other output, or a non-zero exit, is an unrecognized form
  # and a parse failure, never a scraped guess (the §P gate rule / Rule 12).
  defp submit_success?([line], 0), do: task_url?(line)
  defp submit_success?(_lines, _exit_code), do: false

  defp task_url?(line) do
    String.starts_with?(line, @task_url_prefix) and valid_task_id?(task_segment(line))
  end

  defp valid_task_id?(segment), do: segment != "" and not String.contains?(segment, "/")

  defp task_segment(url), do: String.replace_prefix(url, @task_url_prefix, "")

  defp build_submit(url), do: %{task_id: task_segment(url), task_url: url}

  # -- status output parsing ---------------------------------------------------

  defp status_view(lines) do
    case status_line(lines) do
      nil -> nil
      {line, token, title} -> view(line, token, title, lines)
    end
  end

  defp status_line(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(@status_line_regex, line) do
        [_full, token] -> {line, token, ""}
        [_full, token, title] -> {line, token, title}
        _no_match -> nil
      end
    end)
  end

  defp view(status_line, token, title, lines) do
    rest = List.delete(lines, status_line)
    summary_line = Enum.find(rest, &summary_line?/1)
    env_line = Enum.find(rest, fn line -> line != summary_line and env_line?(line) end)

    %{
      state: state_atom(token),
      raw: %{
        status: token,
        title: title,
        env_label: env_label(env_line),
        relative_time: relative_time(env_line),
        summary: summary_line,
        diff: parse_diff(summary_line)
      }
    }
  end

  defp state_atom("PENDING"), do: :pending
  defp state_atom("READY"), do: :ready
  defp state_atom("APPLIED"), do: :applied
  defp state_atom("ERROR"), do: :error

  defp summary_line?(@no_diff), do: true
  defp summary_line?(line), do: Regex.match?(@diff_summary_regex, line)

  defp env_line?(line), do: String.contains?(line, @env_separator) and not summary_line?(line)

  defp env_label(nil), do: nil
  defp env_label(line), do: line |> split_env() |> elem(0)

  defp relative_time(nil), do: nil
  defp relative_time(line), do: line |> split_env() |> elem(1)

  defp split_env(line) do
    case String.split(line, @env_separator, parts: 2) do
      [label, time] -> {label, time}
      _single -> {line, nil}
    end
  end

  defp parse_diff(nil), do: nil
  defp parse_diff(@no_diff), do: :none

  defp parse_diff(line) do
    case Regex.run(@diff_summary_regex, line) do
      [_full, adds, dels, files] ->
        %{
          adds: String.to_integer(adds),
          dels: String.to_integer(dels),
          files: String.to_integer(files)
        }

      _no_match ->
        nil
    end
  end

  # -- shared line helpers -----------------------------------------------------

  defp split_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp signed_out?(lines), do: Enum.any?(lines, &String.starts_with?(&1, @not_signed_in_prefix))

  defp error_detail(lines) do
    case Enum.find(lines, &String.starts_with?(&1, @error_prefix)) do
      nil -> nil
      line -> String.replace_prefix(line, @error_prefix, "")
    end
  end

  defp parse_detail(stdout, exit_code) do
    bounded = stdout |> String.trim() |> String.slice(0, 256)
    "exit=#{exit_code} output=#{inspect(bounded)}"
  end
end
