defmodule Mix.Tasks.Fermix.Eval.Transcription do
  @shortdoc "LIVE speech-to-text eval: grades the sample fixtures through the configured backend(s)"

  @moduledoc """
  Runs the committed transcription fixtures through the operator's **configured**
  speech-to-text backend(s) and grades each transcript by keyword recall.

  This is a LIVE eval: it uploads the sample audio to the real STT APIs
  (OpenAI / xAI / Deepgram, per your config), so it costs API credits and needs
  network access. It is deliberately NOT part of `mix test` — it is a Mix task,
  not a test — and reads the operator's runtime config from `FERMIX_HOME`
  (default `~/.fermix`) without starting the daemon supervision tree.

      mix fermix.eval.transcription [--backend openai|xai|deepgram] [--threshold 0.8]

  With no `--backend` it evals every backend whose key resolves. When no backend
  is configured (or the named one is not), it prints a SKIP message and exits 0.
  It exits non-zero when any eval'd fixture fails its recall threshold.
  """

  use Mix.Task

  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Transcription.Eval
  alias FermixCore.Transcription.Registry

  @switches [backend: :string, threshold: :float]

  @impl Mix.Task
  def run(args) do
    bootstrap()

    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("invalid options: #{inspect(invalid)}")
    end

    execute(opts)
  end

  # Config-only bootstrap: load the compile-time baseline + hydrate FERMIX_HOME
  # config into Application env (resolving @keyring / source="command" secrets)
  # via the same entrypoint the daemon uses, and bring up only the HTTP pool the
  # transcription backends need. No channels, agents, or realtime are started.
  defp bootstrap do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")
    {:ok, _started} = Application.ensure_all_started(:req)
    start_http_pool()
    bootstrap_config()
  end

  defp start_http_pool do
    {:ok, _pid} =
      Finch.start_link(name: FermixCore.Finch, pools: FermixCore.Application.finch_pools())

    :ok
  end

  defp bootstrap_config do
    # Tree-less task (no daemon supervision tree — see @moduledoc): a `@keyring`
    # or `source = "command"` secret resolves inline, so thread `supervised:
    # false`. A supervised run here would raise (no CommandHost.Supervisor).
    case ConfigStore.bootstrap_runtime_config(supervised: false) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("config bootstrap failed: #{inspect(reason)}")
    end
  end

  defp execute(opts) do
    backend = parse_backend(Keyword.get(opts, :backend))
    result = Eval.run(run_opts(backend, opts))

    case result.results do
      [] -> skip(backend)
      _rows -> report(result)
    end
  end

  defp run_opts(backend, opts) do
    []
    |> put_present(:backend, backend)
    |> put_present(:threshold, Keyword.get(opts, :threshold))
  end

  defp put_present(acc, _key, nil), do: acc
  defp put_present(acc, key, value), do: Keyword.put(acc, key, value)

  defp parse_backend(nil), do: nil

  defp parse_backend(name) when is_binary(name) do
    case Enum.find(Registry.backends(), fn {atom, _module} -> Atom.to_string(atom) == name end) do
      {atom, _module} -> atom
      nil -> Mix.raise("unknown --backend #{inspect(name)}; expected one of: #{known_backends()}")
    end
  end

  defp report(%{results: results, summary: summary}) do
    Enum.each(results, &print_row/1)
    print_summary(summary)

    if summary.passed < summary.total do
      Mix.raise("transcription eval FAILED: #{summary.passed}/#{summary.total} fixtures passed")
    end
  end

  defp print_row(%{backend: backend, file: file, recall: recall, pass?: pass?} = row) do
    Mix.shell().info("#{verdict(pass?)}  #{backend}  #{file}  recall=#{percent(recall)}")
    unless pass?, do: print_detail(row)
  end

  defp print_detail(%{error: nil, transcript: transcript}) do
    Mix.shell().info("        transcript: #{inspect(transcript)}")
  end

  defp print_detail(%{error: error}) do
    Mix.shell().info("        error: #{inspect(error)}")
  end

  defp print_summary(summary) do
    Mix.shell().info("")

    Enum.each(summary.per_backend, fn {backend, %{passed: passed, total: total}} ->
      Mix.shell().info("#{backend}: #{passed}/#{total} passed")
    end)

    Mix.shell().info(
      "overall: #{summary.passed}/#{summary.total} passed (threshold #{summary.threshold})"
    )
  end

  defp skip(nil) do
    Mix.shell().info("No transcription backend configured — set one via `fermix setup`.")
  end

  defp skip(backend) do
    Mix.shell().info(
      "Transcription backend #{backend} is not configured — set one via `fermix setup`."
    )
  end

  defp known_backends do
    Enum.map_join(Registry.backends(), ", ", fn {atom, _module} -> Atom.to_string(atom) end)
  end

  defp verdict(true), do: "PASS"
  defp verdict(false), do: "FAIL"

  defp percent(recall), do: "#{Float.round(recall * 100, 1)}%"
end
