defmodule FermixCore.Computers do
  @moduledoc """
  The home's computers (M97 §2, §3.2), on the primary: each a member of the
  home with a record, whatever the engine's role there (the `device` role,
  which keeps its name in configuration; owner-facing text says computer).

  `list/1` joins three sources, one owner each: the computer's device row
  (`Home.Link`'s `computer_rows/0`: its name, system, last `hello`, whether
  it keeps backups, and whether its session is up now), the live facts of
  its session (`Computers.Registry`: the offers it sent in this session and
  the path its session runs), and its record (`Computers.Store`: its engine
  version, when the home last heard it, and its last offers). A connected
  computer offers what its session said, nothing before its first
  `offers`; one that is away is listed with the offers it last said, so the
  model can say it is away rather than guess. Nothing is ever inferred.

  Off the primary there are none: a computer's own list lives on its server.

  `prompt_section/1` is the `## Computers` section (§6.5) on an owner's turn,
  where Always On is offered, on the primary, when the home has a computer.
  `rename/3` is `computers.rename`: names are unique in the home, compared
  without case, and differ from the server's own.

  Seams in `opts`: `:role` (the engine role, `Home.Role.booted/0`'s), `:rows`
  (0-arity, in place of the link's), `:live` (the Registry's live map),
  `:home`, `:records` (the records map), `:server_name`, `:link` (the link
  module), `:always_on` (boolean), `:host_facts`, `:personalization`.
  """

  require Logger

  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Prompt
  alias FermixCore.Computers.Registry
  alias FermixCore.Computers.Store
  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Home.ComputerName
  alias FermixCore.Home.Link
  alias FermixCore.Home.Role
  alias FermixCore.HostFacts
  alias FermixCore.Setup.ConfigStore

  @platforms %{"macos" => :macos, "linux" => :linux}
  @max_name_bytes 64
  @controls ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u

  @doc "Every computer of the home, by name (the moduledoc); none off the primary."
  @spec list(keyword()) :: [Computer.t()]
  def list(opts \\ []) when is_list(opts) do
    if primary?(opts), do: joined(rows(opts), opts), else: []
  end

  @doc "One computer, by its device id or its name (compared without case)."
  @spec get(String.t(), keyword()) :: {:ok, Computer.t()} | {:error, :not_found}
  def get(id_or_name, opts \\ []) when is_binary(id_or_name) and is_list(opts) do
    wanted = String.downcase(id_or_name)

    case Enum.find(
           list(opts),
           &(&1.device_id == id_or_name or String.downcase(&1.name) == wanted)
         ) do
      nil -> {:error, :not_found}
      computer -> {:ok, computer}
    end
  end

  @doc """
  Names the computer `device_id` `name` (`computers.rename`): a name of one
  line, 1 to #{@max_name_bytes} bytes once trimmed, that no other computer
  of the home holds and that is not the server's own, compared without
  case. Each refusal carries the sentence an owner reads.
  """
  @spec rename(String.t(), String.t(), keyword()) ::
          {:ok, Computer.t()}
          | {:error, {:invalid_name | :name_taken | :not_found, String.t()}}
  def rename(device_id, name, opts \\ []) when is_binary(device_id) and is_binary(name) do
    trimmed = String.trim(name)

    with :ok <- valid_name(trimmed),
         :ok <- not_the_server(trimmed, opts),
         {:ok, _row} <- renamed(device_id, trimmed, opts),
         {:ok, computer} <- get(device_id, opts) do
      {:ok, computer}
    else
      {:error, :not_found} -> {:error, {:not_found, not_found_sentence()}}
      {:error, _refusal} = refused -> refused
    end
  end

  @doc """
  The `## Computers` section (M97 §6.5), or nil: only on an owner's turn
  (`trust: :operator`), where Always On is offered, on the primary, and when
  the home has a computer.
  """
  @spec prompt_section(keyword()) :: String.t() | nil
  def prompt_section(opts \\ []) when is_list(opts) do
    with :operator <- Keyword.get(opts, :trust, :operator),
         true <- always_on?(opts),
         [_ | _] = computers <- list(opts) do
      host = Keyword.get_lazy(opts, :host_facts, &HostFacts.current/0)
      Prompt.render(host, computers, Keyword.take(opts, [:personalization]))
    else
      _none -> nil
    end
  end

  @doc "Every sentence a rename refusal says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences do
    [
      invalid_name_sentence(),
      taken_sentence("studio Mac"),
      server_name_sentence("garden server"),
      not_found_sentence()
    ]
  end

  # -- the list ----------------------------------------------------------------

  defp joined({:ok, []}, _opts), do: []

  defp joined({:ok, rows}, opts) do
    live = Keyword.get_lazy(opts, :live, fn -> Registry.live() end)
    records = records(opts)

    rows
    |> Enum.map(&computer(&1, live[&1.device_id], Map.get(records, &1.device_id, %{})))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  defp joined({:error, reason}, _opts) do
    Logger.warning("the home's computers could not be listed: #{inspect(reason)}")
    []
  end

  defp computer(row, live, record) do
    connected = row.connected and live != nil

    %Computer{
      device_id: row.device_id,
      name: row.name,
      platform: Map.get(@platforms, row.platform),
      engine_version: Map.get(record, :engine_version),
      connected: row.connected,
      since: row.since,
      last_seen: latest(row.last_seen, Map.get(record, :seen_at)),
      path: if(connected, do: live.path),
      offers: offers(row.connected, live, record),
      backups: row.backups != false
    }
  end

  # A session's own offers while it is up; the last ones said while it is
  # away, or while the live view restarted under an open session.
  defp offers(true, %{offers: offers}, _record), do: offers
  defp offers(_connected, _live, record), do: Map.get(record, :offers, [])

  defp latest(nil, at), do: at
  defp latest(at, nil), do: at
  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp rows(opts), do: Keyword.get(opts, :rows, fn -> link(opts).computer_rows() end).()

  defp records(opts) do
    case Keyword.fetch(opts, :records) do
      {:ok, records} -> records
      :error -> read_records(Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0))
    end
  end

  defp read_records(home) do
    case Store.read_all(home) do
      {:ok, records} ->
        records

      {:error, reason} ->
        Logger.warning("the home's computer records could not be read: #{inspect(reason)}")
        %{}
    end
  end

  defp primary?(opts) do
    case Keyword.get_lazy(opts, :role, &booted_role/0) do
      :primary -> true
      _other -> false
    end
  end

  defp booted_role do
    case Role.booted() do
      %{role: role} -> role
      nil -> nil
    end
  end

  defp always_on?(opts), do: Keyword.get_lazy(opts, :always_on, &AlwaysOnRelease.available?/0)

  defp link(opts), do: Keyword.get_lazy(opts, :link, &Link.impl/0)

  # -- renaming ------------------------------------------------------------------

  defp valid_name(name) do
    if byte_size(name) in 1..@max_name_bytes and String.valid?(name) and
         not Regex.match?(@controls, name),
       do: :ok,
       else: {:error, {:invalid_name, invalid_name_sentence()}}
  end

  defp not_the_server(name, opts) do
    case Keyword.get_lazy(opts, :server_name, &server_name/0) do
      server when is_binary(server) ->
        if String.downcase(server) == String.downcase(name),
          do: {:error, {:name_taken, server_name_sentence(name)}},
          else: :ok

      nil ->
        :ok
    end
  end

  defp server_name do
    case ComputerName.read() do
      {:ok, name} -> name
      {:error, _reason} -> nil
    end
  end

  defp renamed(device_id, name, opts) do
    case link(opts).rename_computer(device_id, name) do
      {:ok, row} -> {:ok, row}
      {:error, {:name_taken, _name}} -> {:error, {:name_taken, taken_sentence(name)}}
      {:error, {:not_found, _id}} -> {:error, :not_found}
      {:error, reason} -> unsaved(reason)
    end
  end

  defp unsaved(reason) do
    Logger.error("a computer could not be renamed: #{inspect(reason)}")
    {:error, {:invalid_name, "The name could not be saved. See the daemon log."}}
  end

  defp invalid_name_sentence,
    do: "Give the computer a name of one line, at most #{@max_name_bytes} characters."

  defp taken_sentence(name), do: "Another computer of yours is already called #{name}."

  defp server_name_sentence(name), do: "Your server is already called #{name}."

  defp not_found_sentence, do: "Your Fermix has no such computer."
end
