defmodule Fermix.CLI.HomeMoveCommand do
  @moduledoc """
  `fermix home enroll` and `candidates` (M75 §7, §14): a fresh host enrolling
  as a candidate primary, and the candidates the primary holds.

      fermix home enroll --code-file PATH [--snapshot-bucket B --snapshot-region R]
      fermix home candidates [--json]

  - `enroll`, on the new host, makes a fresh home a candidate
    (`FermixCore.Home.Candidate.enroll/3`) with no engine running: it reads
    the code from the file (trimmed), writes `candidate/` and the candidate
    role, and removes the code file. A failure leaves the home as it found
    it, and the code file too. Human output only.
  - `candidates` lists the candidates the primary holds: from the engine
    (`home.candidates.list`), or from the home's file when it is stopped.

  Exit status: `0` done, `1` refused (one sentence on stderr, or the `--json`
  envelope), `2` usage error.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.MachineOutput
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Setup.ConfigStore

  @json [json: :boolean]
  @enroll_switches [
    code_file: :string,
    snapshot_bucket: :string,
    snapshot_region: :string
  ]
  @call_timeout_ms 30_000
  @max_file_bytes 4_096
  @usage """
  Usage:
    fermix home enroll --code-file PATH [--snapshot-bucket B --snapshot-region R]
    fermix home candidates [--json]
  """

  @doc """
  Runs one verb. `deps`: `:home`, `:client` (a 3-arity management call, as
  `Client.request_v1/3`), `:now` (a 0-arity clock).
  """
  @spec run(String.t(), [String.t()], keyword()) :: non_neg_integer()
  def run(verb, argv, deps \\ []) when is_binary(verb) and is_list(argv) and is_list(deps) do
    case verb do
      "enroll" -> enroll(argv, deps)
      "candidates" -> with_json(argv, &candidates(&1, deps))
    end
  end

  # -- enroll -----------------------------------------------------------------

  defp enroll(argv, deps) do
    case OptionParser.parse(argv, strict: @enroll_switches) do
      {opts, [], []} -> enroll_with(opts, deps)
      _invalid -> usage()
    end
  end

  defp enroll_with(opts, deps) do
    with {:ok, code_file} <- required(opts, :code_file),
         {:ok, destination} <- destination(opts),
         {:ok, code_text} <- read_small(Path.expand(code_file)) do
      code_file = Path.expand(code_file)

      enroll_opts = [
        destination: destination,
        now: now(deps),
        consume: fn -> remove_code_file(code_file) end
      ]

      case Candidate.enroll(home(deps), code_text, enroll_opts) do
        {:ok, code} -> enrolled(code)
        {:error, reason} -> enroll_refused(Candidate.error_sentence(reason))
      end
    else
      :usage -> usage()
      {:error, sentence} -> enroll_refused(sentence)
    end
  end

  defp enrolled(code) do
    IO.puts(
      "This home is now a candidate of #{code.name}. Start Fermix: it enrolls with " <>
        "#{code.name}, then waits up to 24 hours for the move."
    )

    0
  end

  # The code is single use, so the file that held it goes once the home holds
  # it, as the enrollment's last step: a code file that cannot be removed
  # undoes the enrollment, so the two never disagree.
  defp remove_code_file(code_file) do
    case File.rm(code_file) do
      :ok -> :ok
      {:error, reason} -> {:error, {:code_file, code_file, reason}}
    end
  end

  defp enroll_refused(sentence) do
    IO.puts(:stderr, "fermix home enroll: " <> sentence)
    1
  end

  defp required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when value != "" -> {:ok, value}
      _missing -> :usage
    end
  end

  defp destination(opts) do
    case {Keyword.get(opts, :snapshot_bucket), Keyword.get(opts, :snapshot_region)} do
      {nil, nil} ->
        {:ok, nil}

      {bucket, region} when is_binary(bucket) and is_binary(region) ->
        {:ok, %{"s3_bucket" => bucket, "s3_region" => region}}

      _half ->
        :usage
    end
  end

  defp read_small(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        read_file(path)

      {:ok, %File.Stat{}} ->
        {:error, "#{path} is not a regular file of at most #{@max_file_bytes} bytes."}

      {:error, reason} ->
        {:error, "#{path} could not be read: #{:file.format_error(reason)}."}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "#{path} could not be read: #{:file.format_error(reason)}."}
    end
  end

  # -- candidates -------------------------------------------------------------

  defp candidates(json?, deps) do
    home = home(deps)

    case client(deps).("home.candidates.list", %{}, call_opts(home)) do
      {:ok, result} -> report(json?, result, &candidate_lines/1)
      {:error, :not_running} -> offline_candidates(home, json?, deps)
      {:error, reason} -> refuse(json?, :home_status_unavailable, output: said(reason))
    end
  end

  defp offline_candidates(home, json?, deps) do
    case Candidates.list(home, now(deps)) do
      {:ok, records} ->
        report(
          json?,
          %{"candidates" => Enum.map(records, &Candidates.view/1)},
          &candidate_lines/1
        )

      {:error, reason} ->
        refuse(json?, :home_status_unavailable, output: Candidates.error_sentence(reason))
    end
  end

  defp candidate_lines(%{"candidates" => []}), do: ["No server is enrolled."]

  defp candidate_lines(%{"candidates" => candidates}) do
    Enum.flat_map(candidates, &candidate_line/1)
  end

  defp candidate_line(candidate) do
    [
      "#{candidate["candidate_id"]}  #{candidate["name"]}  #{candidate["os"]}/#{candidate["arch"]}" <>
        "  enrolled #{candidate["enrolled_at"]}, held until #{candidate["expires_at"]}"
    ]
  end

  # -- output -----------------------------------------------------------------

  # The daemon's own sentence, when it gave one, is what the owner reads.
  defp said({:management_error, _code, message, %{"sentence" => sentence}})
       when is_binary(sentence) and is_binary(message),
       do: sentence

  defp said({:management_error, _code, message, _details}) when is_binary(message), do: message
  defp said(reason), do: Client.describe_error(reason)

  defp report(true, result, _lines) do
    IO.puts(MachineOutput.ok(result))
    0
  end

  defp report(false, result, lines) do
    Enum.each(lines.(result), &IO.puts/1)
    0
  end

  defp refuse(true, code, details) do
    IO.puts(MachineOutput.error(code, details))
    1
  end

  defp refuse(false, code, details) do
    IO.puts(:stderr, "fermix home: " <> MachineOutput.sentence(code, details))
    1
  end

  defp with_json(argv, fun) do
    case OptionParser.parse(argv, strict: @json) do
      {opts, [], []} -> fun.(Keyword.get(opts, :json, false))
      _invalid -> usage()
    end
  end

  defp home(deps), do: Path.expand(Keyword.get_lazy(deps, :home, &ConfigStore.fermix_home/0))
  defp client(deps), do: Keyword.get(deps, :client, &Client.request_v1/3)
  defp now(deps), do: Keyword.get(deps, :now, &DateTime.utc_now/0).()

  defp call_opts(home),
    do: [socket_path: Path.join(home, "daemon.sock"), timeout: @call_timeout_ms]

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end
end
