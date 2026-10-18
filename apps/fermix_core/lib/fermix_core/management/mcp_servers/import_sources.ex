defmodule FermixCore.Management.McpServers.ImportSources do
  @moduledoc """
  The other apps on this Mac whose MCP servers the owner can import (M74 §5,
  E8), and the one reader of their settings files.

  Each source is one fixed file under the home folder, and a closed id the
  wire names it by:

  | id | app | file | servers |
  |---|---|---|---|
  | `claude_desktop` | Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | `mcpServers` |
  | `claude_code` | Claude Code | `~/.claude.json` | `mcpServers`, the user's own; a project's are not read |
  | `cursor` | Cursor | `~/.cursor/mcp.json` | `mcpServers` |
  | `vscode` | VS Code | `~/Library/Application Support/Code/User/mcp.json` | `servers` |
  | `windsurf` | Windsurf | `~/.codeium/windsurf/mcp_config.json` | `mcpServers` |
  | `codex` | Codex | `~/.codex/config.toml` | `[mcp_servers.<name>]` |

  A file is read only when the owner asks (D3): `servers/2` is the only read,
  and nothing here holds what it read, so a scan and the import after it each
  read the file as it is then. A settings file is not a paste: it is bounded by
  its own limit (8 MiB, because `~/.claude.json` keeps far more than servers),
  parsed whole, and only its servers map is handed on, to
  `Interchange.translate_server/4`, one server at a time. A missing file, or
  one without servers, holds none; a file that cannot be opened, is past the
  limit, does not parse, or holds its servers in another shape answers one
  sentence, which never quotes the file, since it may hold keys.
  """

  alias Jason.OrderedObject

  @max_file_bytes 8 * 1024 * 1024
  @sources [
    %{
      id: "claude_desktop",
      label: "Claude Desktop",
      path: "Library/Application Support/Claude/claude_desktop_config.json",
      format: :json,
      key: "mcpServers"
    },
    %{
      id: "claude_code",
      label: "Claude Code",
      path: ".claude.json",
      format: :json,
      key: "mcpServers"
    },
    %{id: "cursor", label: "Cursor", path: ".cursor/mcp.json", format: :json, key: "mcpServers"},
    %{
      id: "vscode",
      label: "VS Code",
      path: "Library/Application Support/Code/User/mcp.json",
      format: :json,
      key: "servers"
    },
    %{
      id: "windsurf",
      label: "Windsurf",
      path: ".codeium/windsurf/mcp_config.json",
      format: :json,
      key: "mcpServers"
    },
    %{id: "codex", label: "Codex", path: ".codex/config.toml", format: :toml, key: "mcp_servers"}
  ]

  @type source :: %{
          id: String.t(),
          label: String.t(),
          path: String.t(),
          format: :json | :toml,
          key: String.t()
        }

  @doc "Every source, in the order a scan reads them."
  @spec all() :: [source()]
  def all, do: @sources

  @doc "The closed set of source ids."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@sources, & &1.id)

  @doc "The largest settings file read, in bytes."
  @spec max_file_bytes() :: pos_integer()
  def max_file_bytes, do: @max_file_bytes

  @doc "The source an id names."
  @spec fetch(String.t()) :: {:ok, source()} | :error
  def fetch(id) when is_binary(id) do
    case Enum.find(@sources, &(&1.id == id)) do
      nil -> :error
      source -> {:ok, source}
    end
  end

  @doc """
  The servers `source`'s file under `home` holds, each by its key there, in
  the file's order (a Codex file's by name, since TOML keeps none), or the
  sentence that says why the file could not be read.
  """
  @spec servers(source(), Path.t()) :: {:ok, [{String.t(), term()}]} | {:error, String.t()}
  def servers(source, home) when is_map(source) and is_binary(home) do
    case read(Path.join(home, source.path)) do
      :missing ->
        {:ok, []}

      {:ok, contents} ->
        contents |> String.trim() |> parsed(source)

      {:error, :too_large} ->
        {:error, "#{source.label}'s settings file is larger than Fermix reads."}

      {:error, _reason} ->
        {:error, "Fermix cannot open #{source.label}'s settings file."}
    end
  end

  # At most one byte past the limit is read, so a file of any size costs no
  # more than the limit to refuse.
  defp read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          bounded(IO.binread(io, @max_file_bytes + 1))
        after
          File.close(io)
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bounded(:eof), do: {:ok, ""}
  defp bounded({:error, reason}), do: {:error, reason}
  defp bounded(data) when byte_size(data) > @max_file_bytes, do: {:error, :too_large}
  defp bounded(data), do: {:ok, data}

  defp parsed("", _source), do: {:ok, []}

  defp parsed(contents, %{format: :json} = source) do
    case Jason.decode(contents, objects: :ordered_objects) do
      {:ok, %OrderedObject{} = document} -> entries(document[source.key], source)
      {:ok, _other} -> {:error, shape_sentence(source)}
      {:error, _reason} -> {:error, "#{source.label}'s settings file is not valid JSON."}
    end
  end

  defp parsed(contents, %{format: :toml} = source) do
    case TomlElixir.decode(contents) do
      {:ok, document} -> entries(Map.get(document, source.key), source)
      {:error, _reason} -> {:error, "#{source.label}'s settings file is not valid TOML."}
    end
  end

  defp entries(nil, _source), do: {:ok, []}
  defp entries(%OrderedObject{values: values}, _source), do: {:ok, values}
  defp entries(table, _source) when is_map(table), do: {:ok, Enum.sort(table)}
  defp entries(_other, source), do: {:error, shape_sentence(source)}

  defp shape_sentence(source),
    do: "#{source.label}'s settings file holds its MCP servers in a shape Fermix does not know."
end
