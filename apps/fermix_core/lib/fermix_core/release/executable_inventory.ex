defmodule FermixCore.Release.ExecutableInventory do
  @moduledoc false

  import Bitwise

  alias FermixCore.Release.Tree

  @native_extensions ~w(.bundle .dylib .so)
  @mach_o_magics [
    <<0xFE, 0xED, 0xFA, 0xCE>>,
    <<0xCE, 0xFA, 0xED, 0xFE>>,
    <<0xFE, 0xED, 0xFA, 0xCF>>,
    <<0xCF, 0xFA, 0xED, 0xFE>>,
    <<0xCA, 0xFE, 0xBA, 0xBE>>,
    <<0xBE, 0xBA, 0xFE, 0xCA>>,
    <<0xCA, 0xFE, 0xBA, 0xBF>>,
    <<0xBF, 0xBA, 0xFE, 0xCA>>
  ]

  @type classifier :: (String.t() -> {:ok, map()} | {:error, term()})

  @spec build([Tree.entry()], String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def build(nodes, architecture, opts \\ [])
      when is_list(nodes) and is_binary(architecture) and is_list(opts) do
    classifier = Keyword.get(opts, :classifier, &classify/1)

    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, entries} ->
      case inventory_entry(node, architecture, classifier) do
        {:ok, nil} -> {:cont, {:ok, entries}}
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1["path"])}
      {:error, _reason} = error -> error
    end
  end

  @spec classify(String.t()) :: {:ok, map()} | {:error, term()}
  def classify(path) when is_binary(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} -> classify_open_file(io, path)
      {:error, reason} -> {:error, {:classification_read_failed, reason}}
    end
  end

  defp inventory_entry(%{type: :directory}, _architecture, _classifier), do: {:ok, nil}

  defp inventory_entry(%{type: :symlink} = node, _architecture, _classifier) do
    {:ok,
     %{
       "path" => node.path,
       "kind" => "symlink",
       "mode" => mode(node.mode),
       "target" => node.target
     }}
  end

  defp inventory_entry(%{type: :file} = node, architecture, classifier) do
    candidate = candidate?(node)

    case classifier.(node.absolute) do
      {:ok, %{kind: "mach_o"} = classification} ->
        build_file_entry(node, architecture, classification)

      {:ok, %{kind: "script"} = classification} when candidate ->
        build_file_entry(node, architecture, classification)

      {:ok, %{kind: "script"}} ->
        {:ok, nil}

      {:ok, _classification} ->
        {:error, {:invalid_classification, node.path}}

      {:error, :unclassified_executable} when candidate ->
        {:error, {:unclassified_executable, node.path}}

      {:error, :unclassified_executable} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:classification_failed, node.path, reason}}
    end
  end

  defp build_file_entry(node, architecture, %{kind: "mach_o", architectures: arches})
       when is_list(arches) do
    normalized = Enum.sort(arches)

    if normalized == [architecture] do
      with {:ok, digest} <- Tree.file_sha256(node.absolute) do
        {:ok,
         %{
           "path" => node.path,
           "kind" => "mach_o",
           "mode" => mode(node.mode),
           "architectures" => normalized,
           "sha256" => digest
         }}
      end
    else
      {:error, {:unexpected_architectures, node.path, normalized, architecture}}
    end
  end

  defp build_file_entry(node, _architecture, %{kind: "script", interpreter: interpreter})
       when is_binary(interpreter) and interpreter != "" do
    cond do
      native_extension?(node.path) ->
        {:error, {:native_file_not_mach_o, node.path}}

      !executable?(node.mode) ->
        {:error, {:script_not_executable, node.path}}

      true ->
        with {:ok, digest} <- Tree.file_sha256(node.absolute) do
          {:ok,
           %{
             "path" => node.path,
             "kind" => "script",
             "mode" => mode(node.mode),
             "interpreter" => interpreter,
             "sha256" => digest
           }}
        end
    end
  end

  defp build_file_entry(node, _architecture, _classification),
    do: {:error, {:invalid_classification, node.path}}

  defp classify_open_file(io, path) do
    read_result = IO.binread(io, 512)
    close_result = File.close(io)

    case {read_result, close_result} do
      {{:error, reason}, :ok} -> {:error, {:classification_read_failed, reason}}
      {:eof, :ok} -> classify_prefix(<<>>, path)
      {data, :ok} when is_binary(data) -> classify_prefix(data, path)
      {_data, {:error, reason}} -> {:error, {:classification_close_failed, reason}}
    end
  end

  defp classify_prefix(<<magic::binary-size(4), _rest::binary>>, path)
       when magic in @mach_o_magics,
       do: classify_mach_o(path)

  defp classify_prefix(<<"#!", _rest::binary>> = data, _path), do: classify_script(data)
  defp classify_prefix(_data, _path), do: {:error, :unclassified_executable}

  defp classify_mach_o(path) do
    case System.cmd("/usr/bin/lipo", ["-archs", path], stderr_to_stdout: true) do
      {output, 0} ->
        architectures = output |> String.trim() |> String.split(~r/\s+/, trim: true)
        {:ok, %{kind: "mach_o", architectures: architectures}}

      {_output, code} ->
        {:error, {:lipo_failed, code}}
    end
  rescue
    error in ErlangError -> {:error, {:lipo_unavailable, error.original}}
  end

  defp classify_script(data) do
    interpreter =
      data
      |> :binary.split("\n")
      |> hd()
      |> String.trim_leading("#!")
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()

    if interpreter == "",
      do: {:error, :unclassified_executable},
      else: {:ok, %{kind: "script", interpreter: interpreter}}
  end

  defp candidate?(node), do: executable?(node.mode) or native_extension?(node.path)
  defp executable?(mode), do: band(mode, 0o111) != 0
  defp native_extension?(path), do: Path.extname(path) in @native_extensions
  defp mode(value), do: value |> Integer.to_string(8) |> String.pad_leading(4, "0")
end
