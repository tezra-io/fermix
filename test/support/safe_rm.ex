defmodule FermixTestSupport.SafeRm do
  @moduledoc """
  Fail-closed cleanup helpers for tests.

  These helpers are intentionally stricter than File.rm*/1. They only delete
  paths that resolve under a Fermix-marked test path and reject ambiguous or
  high-risk locations.
  """

  @spec make_tmp_dir!(String.t()) :: String.t()
  def make_tmp_dir!(prefix) when is_binary(prefix) and prefix != "" do
    suffix =
      "#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"

    dir =
      System.tmp_dir!()
      |> Path.join(safe_prefix(prefix) <> "-#{suffix}")
      |> Path.expand()

    File.mkdir!(dir)
    mark!(dir)
    dir
  end

  @spec mark!(String.t()) :: :ok
  def mark!(path) when is_binary(path) do
    dir = Path.expand(path)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, marker_name()), "")
  end

  @spec rm(String.t()) :: :ok | {:error, term()}
  def rm(path) do
    with {:ok, checked} <- checked_path(path),
         result when result in [:ok, {:error, :enoent}] <- File.rm(checked) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rm!(String.t()) :: :ok
  def rm!(path) do
    case rm(path) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "unsafe test cleanup rejected: #{inspect(reason)}"
    end
  end

  @spec rm_rf(String.t()) :: :ok | {:error, term()}
  def rm_rf(path) do
    with {:ok, checked} <- checked_path(path),
         {:ok, _removed} <- File.rm_rf(checked) do
      :ok
    else
      {:error, reason, failed_path} -> {:error, {reason, failed_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rm_rf!(String.t()) :: :ok
  def rm_rf!(path) do
    case rm_rf(path) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "unsafe test cleanup rejected: #{inspect(reason)}"
    end
  end

  defp checked_path(path) when is_binary(path) and path != "" do
    expanded = Path.expand(path)

    with {:ok, resolved} <- resolve_for_check(expanded),
         :ok <- reject_protected(expanded),
         :ok <- reject_protected(resolved),
         :ok <- reject_shallow(resolved),
         :ok <- require_safe_test_path(expanded, resolved) do
      {:ok, expanded}
    end
  end

  defp checked_path(_path), do: {:error, :invalid_path}

  defp resolve_for_check(path) do
    if File.exists?(path) do
      realpath(path)
    else
      resolve_missing(path)
    end
  end

  defp resolve_missing(path) do
    parent = Path.dirname(path)

    case realpath(parent) do
      {:ok, resolved_parent} -> {:ok, Path.join(resolved_parent, Path.basename(path))}
      {:error, reason} -> {:error, {:unresolved_parent, reason, parent}}
    end
  end

  defp reject_protected(path) do
    if protected_path?(path) do
      {:error, {:protected_path, path}}
    else
      :ok
    end
  end

  defp reject_shallow(path) do
    parts = Path.split(path)

    if length(parts) < 3 do
      {:error, {:path_too_shallow, path}}
    else
      :ok
    end
  end

  defp require_safe_test_path(expanded, resolved) do
    cond do
      marker_in_ancestors?(expanded) -> :ok
      marker_in_ancestors?(resolved) -> :ok
      fermix_tmp_path?(resolved) -> :ok
      true -> {:error, {:missing_test_marker, expanded}}
    end
  end

  defp marker_in_ancestors?(path) do
    path
    |> ancestors()
    |> Enum.any?(&File.exists?(Path.join(&1, marker_name())))
  end

  defp fermix_tmp_path?(path) do
    with {:ok, tmp} <- realpath(System.tmp_dir!()) do
      inside_or_equal?(path, tmp) and Enum.any?(Path.split(path), &fermix_component?/1)
    else
      {:error, _reason} -> false
    end
  end

  defp ancestors(path) do
    path
    |> Path.expand()
    |> do_ancestors([], 64)
  end

  defp do_ancestors(_path, acc, 0), do: acc

  defp do_ancestors(path, acc, remaining) do
    parent = Path.dirname(path)
    acc = [path | acc]

    if parent == path do
      acc
    else
      do_ancestors(parent, acc, remaining - 1)
    end
  end

  defp safe_prefix(prefix) do
    if String.starts_with?(prefix, "fermix-"), do: prefix, else: "fermix-#{prefix}"
  end

  defp protected_path?(path) do
    Enum.any?(protected_paths(), &inside_or_equal?(path, &1)) or unsafe_fermix_home?(path)
  end

  defp protected_paths do
    [
      "/",
      System.user_home!(),
      Path.join(System.user_home!(), ".fermix"),
      Path.join(System.user_home!(), ".fermix-dev"),
      "/etc",
      "/usr",
      "/bin",
      "/sbin",
      "/System",
      "/Library"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
  end

  defp unsafe_fermix_home?(path) do
    case System.get_env("FERMIX_HOME") do
      nil -> false
      home -> inside_or_equal?(path, Path.expand(home)) and not fermix_tmp_path?(path)
    end
  end

  defp realpath(path) do
    path
    |> String.to_charlist()
    |> :file.read_link_all()
    |> case do
      {:ok, chars} -> {:ok, chars |> List.to_string() |> Path.expand()}
      {:error, :einval} -> {:ok, Path.expand(path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inside_or_equal?(path, root), do: path == root or String.starts_with?(path, root <> "/")
  defp fermix_component?(part), do: String.starts_with?(part, "fermix")
  defp marker_name, do: ".fermix-test-root"
end
