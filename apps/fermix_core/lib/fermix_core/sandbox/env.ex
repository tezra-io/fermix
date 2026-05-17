defmodule FermixCore.Sandbox.Env do
  @moduledoc """
  Builds child-process environments from explicit sandbox passthrough config.
  """

  alias FermixCore.Sandbox.Config

  @default_keys ~w(PATH HOME USER LANG SHELL TMPDIR)
  @secret_max_bytes 8_192

  @spec build(Config.t() | map() | keyword(), [String.t()]) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def build(config, extra_names \\ []) do
    config = Config.normalize(config)

    with {:ok, selected} <- selected_env(config, config.env.allow ++ extra_names) do
      {:ok, default_env() |> Map.merge(selected) |> Map.to_list()}
    end
  end

  @spec build_command(Config.t() | map() | keyword(), [String.t()]) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def build_command(config, pass_env) when is_list(pass_env) do
    config = Config.normalize(config)

    with :ok <- validate_pass_env(config, pass_env),
         {:ok, selected} <- selected_env(config, pass_env) do
      {:ok, default_env() |> Map.merge(selected) |> Map.to_list()}
    end
  end

  defp selected_env(%Config{env: %{mode: :all} = env}, names) do
    denied = MapSet.new(env.deny)

    if names == [] do
      System.get_env()
      |> Enum.reject(fn {name, _value} -> MapSet.member?(denied, name) end)
      |> Map.new()
      |> then(&{:ok, &1})
    else
      names
      |> Enum.reject(&MapSet.member?(denied, &1))
      |> resolve_names(env.sources)
    end
  end

  defp selected_env(%Config{env: env}, names) do
    names |> Enum.uniq() |> resolve_names(env.sources)
  end

  defp resolve_names(names, sources) do
    Enum.reduce_while(Enum.uniq(names), {:ok, %{}}, fn name, {:ok, acc} ->
      case resolve_name(name, sources) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_pass_env(%Config{env: %{mode: :all} = env}, pass_env) do
    denied = MapSet.new(env.deny)

    case Enum.find(pass_env, &MapSet.member?(denied, &1)) do
      nil -> :ok
      name -> {:error, {:env_denied, name}}
    end
  end

  defp validate_pass_env(%Config{env: env}, pass_env) do
    allowed = MapSet.new(env.allow)

    case Enum.find(pass_env, &(not MapSet.member?(allowed, &1))) do
      nil -> :ok
      name -> {:error, {:env_not_allowed, name}}
    end
  end

  defp resolve_name(name, sources) do
    source = Map.get(sources, name, %{source: :env, name: name})

    case source.source do
      :env -> read_env(source.name || name)
      :command -> read_command(source)
    end
  end

  defp read_env(name) do
    case System.get_env(name) do
      nil -> {:error, {:missing_env, name}}
      value -> {:ok, value}
    end
  end

  defp read_command(%{command: command, args: args, timeout_ms: timeout})
       when is_binary(command) do
    task = Task.async(fn -> System.cmd(command, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        normalize_secret_output(output)

      {:ok, {output, code}} ->
        {:error, {:env_command_failed, command, code, String.slice(output, 0, 200)}}

      nil ->
        {:error, {:env_command_timeout, command, timeout}}
    end
  end

  defp read_command(_source), do: {:error, :invalid_env_command_source}

  defp normalize_secret_output(output) when byte_size(output) <= @secret_max_bytes do
    output
    |> trim_one_trailing_newline()
    |> case do
      "" -> {:error, :empty_env_command_output}
      value when is_binary(value) ->
        if String.contains?(value, ["\n", "\r"]),
          do: {:error, :env_command_output_not_single_value},
          else: {:ok, value}

      value -> {:ok, value}
    end
  end

  defp normalize_secret_output(_output), do: {:error, :env_command_output_too_large}

  defp trim_one_trailing_newline(output) do
    if String.ends_with?(output, "\n") do
      binary_part(output, 0, byte_size(output) - 1)
    else
      output
    end
  end

  defp default_env do
    System.get_env()
    |> Enum.filter(fn {name, _value} ->
      name in @default_keys or String.starts_with?(name, "LC_")
    end)
    |> Map.new()
  end
end
