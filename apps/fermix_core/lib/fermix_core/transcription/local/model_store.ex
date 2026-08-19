defmodule FermixCore.Transcription.Local.ModelStore do
  @moduledoc """
  Owns the on-disk ASR models the `fermix-stt` sidecar loads.

  The catalog is **internal**: `{engine, model}` maps to the ordered list of
  files that model consists of, and it is never rendered as a user-facing menu.
  The local backend has exactly one model in this phase; the operator chooses
  the *backend*, not a checkpoint.

  Everything lives under `FERMIX_HOME/models/stt/<engine>/<model>/`. That tree is
  created here, at install time — deliberately not a `ConfigStore` workspace
  directory, so a fresh home never grows an empty model tree it may never use.

  ## Integrity

  Each file is downloaded to a staging directory, verified against its pinned
  sha256, and only then renamed into place — so a partially downloaded or
  tampered model can never be mistaken for an installed one. `installed?/2`
  checks presence only: integrity was proven at install, and re-hashing hundreds
  of megabytes on every hot-path read would be the wrong trade.

  ## Pins

  `@sha256_pinned` is `true`: every `sha256:` in the catalog was minted by
  downloading the file once and hashing it (never hand-written). A build with
  `@sha256_pinned` `false` refuses with `{:error, :model_pins_missing}` rather
  than downloading unverified weights — reachable in tests through the
  `sha256_pinned:` seam. The `catalog:` option is the test seam that proves the
  whole download → verify → rename path against a fake catalog with real hashes.
  """

  require Logger

  alias FermixCore.Net.StreamDownload
  alias FermixCore.Setup.ConfigStore

  # `true` once every `sha256:` below is minted (v0.1.0). Never pin a value
  # without downloading the file and hashing it.
  @sha256_pinned true

  @hf_base "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main"

  # NOTE: the member names follow the upstream repo tree — confirm each against
  # the Hugging Face repo when the pins are minted (an int8 export may ship a
  # fp32 joiner only) and record what was pinned. The catalog SHAPE is the
  # contract; the exact file names follow the repo.
  @catalog %{
    {"sherpa-onnx", "parakeet-tdt-0.6b-v3-int8"} => [
      %{
        name: "encoder.int8.onnx",
        url: @hf_base <> "/encoder.int8.onnx",
        sha256: "acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247"
      },
      %{
        name: "decoder.int8.onnx",
        url: @hf_base <> "/decoder.int8.onnx",
        sha256: "179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e"
      },
      %{
        name: "joiner.int8.onnx",
        url: @hf_base <> "/joiner.int8.onnx",
        sha256: "3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3"
      },
      %{
        name: "tokens.txt",
        url: @hf_base <> "/tokens.txt",
        sha256: "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d"
      }
    ]
  }

  @model_pins_missing_message "The on-device speech model has no sha256 pins in this fermix build " <>
                                "yet — they land with the first fermix-stt release. Until then, " <>
                                "install the model files yourself under " <>
                                "FERMIX_HOME/models/stt/<engine>/<model>/."

  @typedoc "One file of a model: its name on disk, where it comes from, and its pinned digest."
  @type file_entry :: %{name: String.t(), url: String.t(), sha256: String.t()}

  @typedoc "`{engine, model}` to the ordered files that model consists of."
  @type catalog :: %{{String.t(), String.t()} => [file_entry()]}

  @typedoc "Install progress, reported once per file per stage."
  @type progress_event :: {:model, :downloading | :verifying}

  @doc "True once the baked catalog carries real sha256 pins."
  @spec pins_pinned?() :: boolean()
  def pins_pinned?, do: @sha256_pinned

  @doc "Operator-facing copy for an unpinned-model refusal, rendered verbatim by doctor and setup."
  @spec error_message(:model_pins_missing) :: String.t()
  def error_message(:model_pins_missing), do: @model_pins_missing_message

  @doc "The root of the model tree: `FERMIX_HOME/models/stt`."
  @spec model_root() :: Path.t()
  def model_root, do: Path.join([ConfigStore.fermix_home(), "models", "stt"])

  @doc """
  The ordered file names a catalog model consists of. Exposed so doctor and the
  tests can talk about a model's on-disk shape without reaching into the catalog.
  """
  @spec file_names(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, {:unknown_model, String.t(), String.t()}}
  def file_names(engine, model) when is_binary(engine) and is_binary(model) do
    case lookup(@catalog, engine, model) do
      {:ok, files} -> {:ok, Enum.map(files, & &1.name)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The directory holding an installed model, or `{:error, :model_not_installed}`.
  Never downloads — this runs on the transcribe hot path.
  """
  @spec model_dir(String.t(), String.t()) :: {:ok, Path.t()} | {:error, :model_not_installed}
  def model_dir(engine, model) when is_binary(engine) and is_binary(model) do
    case installed?(engine, model) do
      true -> {:ok, dir(engine, model)}
      false -> {:error, :model_not_installed}
    end
  end

  @doc """
  True when every file of the model is present as a regular file. Presence only:
  the sha256 was verified at install, before the files were moved into place.
  """
  @spec installed?(String.t(), String.t()) :: boolean()
  def installed?(engine, model) when is_binary(engine) and is_binary(model) do
    case file_names(engine, model) do
      {:ok, names} -> present?(dir(engine, model), names)
      {:error, _reason} -> false
    end
  end

  @doc """
  Downloads and verifies every file of a model, then moves it into place
  atomically. Already installed is `:ok` without a single request.

  Called only from `FermixCore.Transcription.Local.ensure_installed/1` (the setup
  surface) and from tests — never at boot, and never as a side effect of setting
  `backend = "local"` by hand.

  `opts` carries the test/DI seams `catalog:`, `sha256_pinned:` and
  `req_options:`, plus `progress:` — an arity-1 function the setup card renders,
  receiving `t:progress_event/0`.
  """
  @spec install(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def install(engine, model, opts \\ [])
      when is_binary(engine) and is_binary(model) and is_list(opts) do
    case Keyword.fetch(opts, :catalog) do
      {:ok, catalog} -> install_from(catalog, engine, model, opts)
      :error -> baked_install(engine, model, opts)
    end
  end

  # The baked catalog is installable only once its pins exist; an unpinned
  # download would defeat the very check that makes the model trustworthy.
  # `sha256_pinned:` is the seam that proves the far side of that gate before
  # the pins are minted.
  defp baked_install(engine, model, opts) do
    pinned = Keyword.get(opts, :sha256_pinned, pins_pinned?())
    pinned_install(pinned, engine, model, opts)
  end

  defp pinned_install(true, engine, model, opts), do: install_from(@catalog, engine, model, opts)
  defp pinned_install(false, _engine, _model, _opts), do: {:error, :model_pins_missing}

  defp install_from(catalog, engine, model, opts) do
    case lookup(catalog, engine, model) do
      {:ok, files} -> ensure_files(files, dir(engine, model), opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_files(files, dir, opts) do
    case present?(dir, Enum.map(files, & &1.name)) do
      true -> :ok
      false -> stage(files, dir, opts)
    end
  end

  # Staging sits beside the final directory (same filesystem), so the last step
  # is one atomic rename: either the whole verified model is there or none of it.
  defp stage(files, dir, opts) do
    staging = Path.join(model_root(), ".staging-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(staging),
         :ok <- fetch_all(files, staging, opts),
         :ok <- File.mkdir_p(Path.dirname(dir)),
         :ok <- replace(staging, dir) do
      :ok
    else
      {:error, reason} ->
        discard(staging)
        {:error, reason}
    end
  end

  # A leftover partial directory would make `File.rename/2` fail; it is our own
  # tree and it is by definition incomplete, so it goes.
  defp replace(staging, dir) do
    _ = File.rm_rf(dir)
    File.rename(staging, dir)
  end

  defp fetch_all(files, staging, opts) do
    progress = Keyword.get(opts, :progress, &noop_progress/1)
    req_options = Keyword.get(opts, :req_options, [])

    Enum.reduce_while(files, :ok, fn file, :ok ->
      case fetch(file, staging, req_options, progress) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch(file, staging, req_options, progress) do
    path = Path.join(staging, file.name)
    progress.({:model, :downloading})

    with :ok <- StreamDownload.download(file.url, path, req_options) do
      progress.({:model, :verifying})
      verify(path, file.name, file.sha256)
    end
  end

  # The `StreamDownload` mismatch shape is passed through unchanged — a model
  # whose bytes do not match its pin is the one failure nobody may paper over.
  defp verify(path, name, sha256) do
    case StreamDownload.check_sha256(path, sha256) do
      :ok ->
        :ok

      {:error, {:sha256_mismatch, expected: expected, actual: actual}} = error ->
        Logger.error(
          "stt model file #{name} failed its checksum: expected #{expected}, got #{actual}"
        )

        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discard(staging) do
    _ = File.rm_rf(staging)
    :ok
  end

  defp lookup(catalog, engine, model) do
    case Map.fetch(catalog, {engine, model}) do
      {:ok, files} -> {:ok, files}
      :error -> {:error, {:unknown_model, engine, model}}
    end
  end

  defp present?(_dir, []), do: false
  defp present?(dir, names), do: Enum.all?(names, &File.regular?(Path.join(dir, &1)))

  defp dir(engine, model), do: Path.join([model_root(), engine, model])

  defp noop_progress(_event), do: :ok
end
