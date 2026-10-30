defmodule Fermix.CLI.HomeMoveCommand do
  @moduledoc """
  `fermix home enroll-code`, `enroll`, `candidates` and `move` (M75 §7, §14):
  moving a home to a candidate primary.

      fermix home enroll-code [--json]
      fermix home enroll --code-file PATH [--snapshot-bucket B --snapshot-region R]
                         [--instance-file PATH]
      fermix home candidates [--json]
      fermix home move --to ID [--recovery-passphrase-file PATH] [--retire] [--json]

  - `enroll-code`, on the primary, asks its engine for an enrollment code
    (`home.enroll.open`): valid for thirty minutes, single use, shown once.
    It needs the running engine (`engine_stopped` otherwise).
  - `enroll`, on the new host, makes a fresh home a candidate
    (`FermixCore.Home.Candidate.enroll/3`) with no engine running: it reads
    the code from the file (trimmed), the instance facts from
    `--instance-file` (`{provider, instance_id, region}` and an optional
    `account_id`, shown unverified; a provisioner writes that file, and the
    first boot passes none), writes `candidate/` and the candidate
    role, and removes the code file. A failure leaves the home as it found
    it, and the code file too. Human output only.
  - `candidates` lists the candidates the primary holds: from the engine
    (`home.candidates.list`), or from the home's file when it is stopped.
  - `move` starts the move (`home.move.start`): the running engine writes the
    request and restarts in the device role; with the engine stopped the
    request and the role are written here, and the move starts when the engine
    does. The recovery passphrase never enters argv: `--recovery-passphrase-file`
    (one line, a trailing newline dropped) or, on a terminal, asked twice
    without echo. This computer becomes a desktop of the new primary, unless
    `--retire` says otherwise (`keep_as_desktop: false`): a server that is
    itself the primary, being replaced by another and then destroyed, hands
    the home over and then serves nothing.

  Exit status: `0` done, `1` refused (one sentence on stderr, or the `--json`
  envelope), `2` usage error.
  """

  alias Fermix.CLI.Daemon.Client
  alias Fermix.CLI.HomeCommand
  alias Fermix.CLI.MachineOutput
  alias Fermix.CLI.SecretInput
  alias FermixCore.Home.Candidate
  alias FermixCore.Home.Candidates
  alias FermixCore.Home.Move
  alias FermixCore.Home.Role
  alias FermixCore.Management.HomeMove
  alias FermixCore.Setup.ConfigStore

  @json [json: :boolean]
  @enroll_switches [
    code_file: :string,
    snapshot_bucket: :string,
    snapshot_region: :string,
    instance_file: :string
  ]
  @move_switches [
    to: :string,
    recovery_passphrase_file: :string,
    retire: :boolean,
    json: :boolean
  ]
  @call_timeout_ms 30_000
  # `home.move.start` walks the home for its readiness report before it
  # answers; the management PROTOCOL.md asks a client to allow it 65 s.
  @move_timeout_ms 65_000
  @max_file_bytes 4_096
  @usage """
  Usage:
    fermix home enroll-code [--json]
    fermix home enroll --code-file PATH [--snapshot-bucket B --snapshot-region R] [--instance-file PATH]
    fermix home candidates [--json]
    fermix home move --to ID [--recovery-passphrase-file PATH] [--retire] [--json]
  """

  @doc """
  Runs one verb. `deps`: `:home`, `:client` (a 3-arity management call, as
  `Client.request_v1/3`), `:terminal`, `:now` (a 0-arity clock).
  """
  @spec run(String.t(), [String.t()], keyword()) :: non_neg_integer()
  def run(verb, argv, deps \\ []) when is_binary(verb) and is_list(argv) and is_list(deps) do
    case verb do
      "enroll-code" -> with_json(argv, &enroll_code(&1, deps))
      "enroll" -> enroll(argv, deps)
      "candidates" -> with_json(argv, &candidates(&1, deps))
      "move" -> move(argv, deps)
    end
  end

  # -- enroll-code ------------------------------------------------------------

  defp enroll_code(json?, deps) do
    case client(deps).("home.enroll.open", %{}, call_opts(home(deps))) do
      {:ok, result} -> report(json?, result, &code_lines/1)
      {:error, :not_running} -> refuse(json?, :engine_stopped, [])
      {:error, reason} -> refuse(json?, :enrollment_refused, output: said(reason))
    end
  end

  defp code_lines(%{"code" => code, "expires_at" => at}) do
    [
      "Enrollment code, valid once until #{at}:",
      "",
      code,
      "",
      "Paste it where the new server asks for it. Fermix shows it only now; open another " <>
        "with fermix home enroll-code if this one runs out."
    ]
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
         {:ok, code_text} <- read_small(Path.expand(code_file)),
         {:ok, instance} <- instance(opts) do
      code_file = Path.expand(code_file)

      enroll_opts = [
        destination: destination,
        instance: instance,
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

  defp instance(opts) do
    case Keyword.fetch(opts, :instance_file) do
      {:ok, path} -> read_instance(Path.expand(path))
      :error -> {:ok, nil}
    end
  end

  defp read_instance(path) do
    with {:ok, text} <- read_small(path) do
      case Jason.decode(text) do
        {:ok, %{} = facts} -> {:ok, facts}
        _other -> {:error, "The instance file #{path} is not a JSON object."}
      end
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

  defp candidate_lines(%{"candidates" => []}),
    do: ["No candidate is enrolled. Open a code with fermix home enroll-code."]

  defp candidate_lines(%{"candidates" => candidates}) do
    Enum.flat_map(candidates, &candidate_line/1)
  end

  defp candidate_line(candidate) do
    [
      "#{candidate["candidate_id"]}  #{candidate["name"]}  #{candidate["os"]}/#{candidate["arch"]}" <>
        "  enrolled #{candidate["enrolled_at"]}, held until #{candidate["expires_at"]}"
    ] ++ instance_line(candidate["instance"])
  end

  defp instance_line(%{"provider" => provider, "instance_id" => id} = facts) do
    ["  #{provider} instance #{id} in #{facts["region"]}#{account(facts)} (unverified)"]
  end

  defp instance_line(_none), do: []

  defp account(%{"account_id" => account}), do: ", account #{account}"
  defp account(_facts), do: ""

  # -- move -------------------------------------------------------------------

  defp move(argv, deps) do
    case OptionParser.parse(argv, strict: @move_switches) do
      {opts, [], []} -> move_with(opts, deps)
      _invalid -> usage()
    end
  end

  defp move_with(opts, deps) do
    json? = Keyword.get(opts, :json, false)

    with {:ok, to} <- required(opts, :to),
         {:ok, passphrase} <- recovery_passphrase(opts, deps) do
      start_move(json?, {to, Keyword.get(opts, :retire, false)}, passphrase, deps)
    else
      :usage ->
        usage()

      {:error, reason} ->
        refuse(json?, :move_refused, output: HomeCommand.passphrase_sentence(reason))
    end
  end

  # `retire?`: the move keeps no desktop here (`keep_as_desktop: false`); the
  # parameter is sent only then, so the engine's default stays the one place
  # that says what a plain move keeps.
  defp start_move(json?, {to, retire?}, passphrase, deps) do
    home = home(deps)
    params = %{"candidate_id" => to, "recovery_passphrase" => passphrase}
    params = if retire?, do: Map.put(params, "keep_as_desktop", false), else: params

    case client(deps).("home.move.start", params, call_opts(home, @move_timeout_ms)) do
      {:ok, result} -> report(json?, result, &move_lines/1)
      {:error, :not_running} -> offline_move(home, json?, {to, retire?}, passphrase, deps)
      {:error, reason} -> refuse(json?, :move_refused, output: said(reason))
    end
  end

  # With the engine stopped the request and the role are written here, and
  # the move starts at the engine's next start.
  defp offline_move(home, json?, {to, retire?}, passphrase, deps) do
    with {:ok, record} <- Role.configured(home),
         {:ok, started} <-
           Move.start(
             home,
             record,
             to,
             passphrase,
             [now: now(deps), supervised: false, keep_as_desktop: not retire?] ++
               Keyword.take(deps, [:free_bytes, :version, :host])
           ) do
      view =
        Map.put(
          HomeMove.started_view(started),
          "sentence",
          "The move to #{started.candidate.name} is set up. Start Fermix: " <>
            offline_start(retire?)
        )

      report(json?, view, &move_lines/1)
    else
      {:error, reason} -> refuse(json?, :move_refused, output: Move.error_sentence(reason))
    end
  end

  defp offline_start(false), do: "it starts in the device role and moves this home."
  defp offline_start(true), do: "it moves this home and then serves nothing here."

  defp move_lines(result) do
    [
      result["sentence"],
      "Move #{result["move_id"]} to #{result["candidate"]["name"]}.",
      "Recovery key (key id #{result["key_id"]}): #{result["recovery_recipient"]}"
    ]
  end

  defp recovery_passphrase(opts, deps) do
    case Keyword.fetch(opts, :recovery_passphrase_file) do
      {:ok, path} -> HomeCommand.read_passphrase_file(Path.expand(path))
      :error -> ask_twice(deps)
    end
  end

  defp ask_twice(deps) do
    with {:ok, first} <- ask("Recovery passphrase", deps),
         {:ok, second} <- ask("Repeat the passphrase", deps) do
      if first == second, do: {:ok, first}, else: {:error, :passphrases_differ}
    end
  end

  defp ask(label, deps) do
    case SecretInput.read_masked(label, Keyword.take(deps, [:terminal])) do
      {:ok, value} -> {:ok, value}
      {:error, :not_a_terminal} -> {:error, :no_passphrase_source}
      {:error, reason} -> {:error, {:passphrase_prompt, reason}}
    end
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

  defp call_opts(home, timeout_ms \\ @call_timeout_ms),
    do: [socket_path: Path.join(home, "daemon.sock"), timeout: timeout_ms]

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end
end
