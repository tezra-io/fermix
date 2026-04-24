defmodule Mix.Tasks.Fermix.Resource.Common do
  @moduledoc false

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Resource.Registry
  alias FermixCore.Resource.Revision

  @switches [
    agent: :string,
    scope: :string,
    limit: :integer,
    yes: :boolean,
    context: :integer
  ]

  @spec parse!(list(String.t())) :: {keyword(), list(String.t())}
  def parse!(args) when is_list(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)

    case invalid do
      [] -> {opts, argv}
      _invalid -> Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  @spec ensure_repo!() :: :ok
  def ensure_repo! do
    Mix.Task.run("loadpaths")
    {:ok, _apps} = Application.ensure_all_started(:exqlite)
    repo = Config.repo_server()

    if Repo.enabled_server(repo) do
      :ok
    else
      start_repo!(repo)
    end

    unless Repo.enabled?(server: repo) do
      Mix.raise("resource registry is unavailable because durable memory is disabled")
    end
  end

  @spec repo_opts() :: keyword()
  def repo_opts, do: [repo: Config.repo_server()]

  @spec agent_id(keyword()) :: String.t()
  def agent_id(opts), do: Keyword.get(opts, :agent, Config.agent_id())

  @spec scope_id(keyword()) :: String.t()
  def scope_id(opts), do: Keyword.get(opts, :scope, "global")

  @spec positive_integer!(String.t(), String.t()) :: pos_integer()
  def positive_integer!(value, label) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> Mix.raise("#{label} must be a positive integer")
    end
  end

  @spec current_revision!(String.t(), String.t(), String.t()) :: Revision.t()
  def current_revision!(agent_id, resource_type, scope_id) do
    with {:ok, resource} <- Registry.get_resource(agent_id, resource_type, scope_id, repo_opts()),
         true <- resource.current_revision > 0,
         {:ok, revision} <-
           Registry.get_revision(
             agent_id,
             resource_type,
             scope_id,
             resource.current_revision,
             repo_opts()
           ) do
      revision
    else
      false -> Mix.raise("resource has no revisions: #{resource_type} scope #{scope_id}")
      {:error, reason} -> Mix.raise("failed to load current revision: #{inspect(reason)}")
    end
  end

  @spec revision!(String.t(), String.t(), String.t(), pos_integer()) :: Revision.t()
  def revision!(agent_id, resource_type, scope_id, revision_number) do
    case Registry.get_revision(agent_id, resource_type, scope_id, revision_number, repo_opts()) do
      {:ok, revision} ->
        revision

      {:error, reason} ->
        Mix.raise("failed to load revision #{revision_number}: #{inspect(reason)}")
    end
  end

  @spec format_timestamp(DateTime.t()) :: String.t()
  def format_timestamp(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  @spec format_size(non_neg_integer() | nil) :: String.t()
  def format_size(nil), do: "--"
  def format_size(bytes) when bytes < 1024, do: "#{bytes}B"

  def format_size(bytes) when is_integer(bytes) do
    kb = bytes / 1024
    :erlang.float_to_binary(kb, decimals: 1) <> "KB"
  end

  @spec short_hash(String.t() | nil) :: String.t()
  def short_hash(nil), do: "--"
  def short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 8)

  @spec table([String.t()], [[String.t()]]) :: String.t()
  def table(headers, rows) when is_list(headers) and is_list(rows) do
    widths = column_widths([headers | rows])
    separator = separator(widths)

    ([format_row(headers, widths), separator] ++ Enum.map(rows, &format_row(&1, widths)))
    |> Enum.join("\n")
  end

  @spec label(Revision.t(), String.t() | nil) :: String.t()
  def label(%Revision{} = revision, suffix \\ nil) do
    base =
      "#{revision.resource_type} @ revision #{revision.revision} (#{format_timestamp(revision.created_at)})"

    if suffix do
      "#{base} #{suffix}"
    else
      base
    end
  end

  @spec print_diff(String.t() | :identical, String.t()) :: :ok
  def print_diff(:identical, message), do: Mix.shell().info(message)

  def print_diff(diff, _message) when is_binary(diff),
    do: Mix.shell().info(String.trim_trailing(diff))

  @spec memory_rebuild_caveat(String.t()) :: String.t() | nil
  def memory_rebuild_caveat("user_md") do
    "Caveat: rolling back USER.md restores the file only; a future rebuild can overwrite it if promoted memories are unchanged."
  end

  def memory_rebuild_caveat("memory_md") do
    "Caveat: rolling back MEMORY.md restores the file only; a future rebuild can overwrite it if promoted memories are unchanged."
  end

  def memory_rebuild_caveat(_resource_type), do: nil

  @spec checkpoint_rollback_message() :: String.t()
  def checkpoint_rollback_message do
    "Checkpoint rollback is not supported; checkpoint revisions are audit/history records only."
  end

  defp start_repo!(repo) do
    case Repo.start_link(name: repo) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> Mix.raise("failed to start resource registry repo: #{inspect(reason)}")
    end
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip()
    |> Enum.map(fn column ->
      column
      |> Tuple.to_list()
      |> Enum.map(&String.length/1)
      |> Enum.max()
    end)
  end

  defp separator(widths) do
    widths
    |> Enum.map(&String.duplicate("-", &1))
    |> Enum.join("-|-")
  end

  defp format_row(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map(fn {value, width} -> String.pad_trailing(value, width) end)
    |> Enum.join(" | ")
  end
end
