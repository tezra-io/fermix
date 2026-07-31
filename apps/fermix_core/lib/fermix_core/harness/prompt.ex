defmodule FermixCore.Harness.Prompt do
  @moduledoc """
  Chooses how a prompt is transported to a vendor CLI: inline as a positional
  argv, or — when it exceeds the argv byte cap — spilled to a `brief.md` file with
  a short pointer prompt taking its place (design §6.1).

  There is no stdin transport (Erlang ports cannot half-close), so an oversized
  prompt becomes `artifacts_dir/brief.md` (written 0600) and the positional prompt
  becomes a pointer to it. The default cap is 200 KiB; callers pass the configured
  `prompt_argv_max_kb` value as `:max_argv_bytes`.

  This module does not own the artifacts directory: it refuses a missing directory
  rather than creating one (the caller creates it 0700). Resource ownership stays
  with the future Artifacts module.
  """

  @default_max_argv_bytes 200 * 1024
  @brief_name "brief.md"
  @brief_mode 0o600
  @pointer_template "Your full brief is at __PATH__. Read it first, then execute it."

  @type transport_result ::
          {:argv, String.t()}
          | {:brief, pointer :: String.t(), brief_path :: String.t()}

  @type reason :: :empty_prompt | :relative_dir | {:missing_dir, String.t()}

  @type opt :: {:max_argv_bytes, pos_integer()}

  @doc """
  Decides the transport for `prompt` given the run's `artifacts_dir`.

  `{:ok, {:argv, prompt}}` when `byte_size(prompt) <= max_argv_bytes`; otherwise
  `{:ok, {:brief, pointer, brief_path}}` after writing the brief. `artifacts_dir`
  must be absolute; for the brief path it must already exist.
  """
  @spec transport(String.t(), String.t(), [opt()]) ::
          {:ok, transport_result()} | {:error, reason()}
  def transport(prompt, artifacts_dir, opts \\ [])
      when is_binary(prompt) and is_binary(artifacts_dir) and is_list(opts) do
    max = validate_max!(opts)

    with :ok <- ensure_non_empty(prompt),
         :ok <- ensure_absolute(artifacts_dir) do
      route(prompt, artifacts_dir, max)
    end
  end

  defp route(prompt, _artifacts_dir, max) when byte_size(prompt) <= max do
    {:ok, {:argv, prompt}}
  end

  defp route(prompt, artifacts_dir, _max) do
    with :ok <- ensure_dir(artifacts_dir) do
      write_brief(prompt, artifacts_dir)
    end
  end

  defp write_brief(prompt, artifacts_dir) do
    path = Path.join(artifacts_dir, @brief_name)
    File.write!(path, prompt)
    File.chmod!(path, @brief_mode)
    {:ok, {:brief, pointer(path), path}}
  end

  defp pointer(path), do: String.replace(@pointer_template, "__PATH__", path)

  defp ensure_non_empty(""), do: {:error, :empty_prompt}
  defp ensure_non_empty(_prompt), do: :ok

  defp ensure_absolute("/" <> _rest), do: :ok
  defp ensure_absolute(_relative), do: {:error, :relative_dir}

  defp ensure_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      {:error, {:missing_dir, dir}}
    end
  end

  defp validate_max!(opts) do
    case Keyword.get(opts, :max_argv_bytes, @default_max_argv_bytes) do
      value when is_integer(value) and value > 0 ->
        value

      other ->
        raise ArgumentError, "max_argv_bytes must be a positive integer, got: #{inspect(other)}"
    end
  end
end
