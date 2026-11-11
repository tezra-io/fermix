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
  Each stands against this engine's version (`Computers.Versions`, §3.4):
  a connected one as its session's hello found it, any other by the version
  its record holds, and one whose version is not known is not served. One
  not served (`:settings_only`) offers nothing until it updates, whatever it
  said.

  Off the primary there are none: a computer's own list lives on its server.

  `visible?/1` is the one rule for whether a turn can see the computers (an
  owner's turn, where Always On is offered, on the primary), decided before
  the link is asked. `prompt_section/1` is the `## Computers` section (§6.5)
  on such a turn, when the home has a computer.
  `rename/3` is `computers.rename`: names are unique in the home, compared
  without case, and differ from the server's own.

  Seams in `opts`: `:role` (the engine role, `Home.Role.booted/0`'s), `:rows`
  (0-arity, in place of the link's), `:live` (the Registry's live map),
  `:home`, `:records` (the records map), `:server_name`, `:link` (the link
  module), `:always_on` (boolean), `:host_facts`, `:personalization`,
  `:version` (this engine's, `BuildInfo.product_version/0`).
  """

  require Logger

  alias FermixCore.BuildInfo
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Invocation
  alias FermixCore.Computers.Prompt
  alias FermixCore.Computers.Registry
  alias FermixCore.Computers.Store
  alias FermixCore.Computers.Versions
  alias FermixCore.Home.AlwaysOnRelease
  alias FermixCore.Home.ComputerName
  alias FermixCore.Home.Link
  alias FermixCore.Home.Role
  alias FermixCore.HostFacts
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Temporal.Access

  @platforms %{"macos" => :macos, "linux" => :linux}
  @max_name_bytes 64
  @controls ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u

  @doc """
  Every computer of the home, by name (the moduledoc); none off the primary.
  Rows the link cannot read are not known: `{:error, reason}`, never none,
  so a caller that must not read "no computers" into it (an Always On
  server's update, `Management.Home`) holds instead.
  """
  @spec fetch(keyword()) :: {:ok, [Computer.t()]} | {:error, term()}
  def fetch(opts \\ []) when is_list(opts) do
    if primary?(opts), do: joined(rows(opts), opts), else: {:ok, []}
  end

  @doc """
  `fetch/1` for a turn: a list that cannot be read is said in the log and
  reaches no computer.
  """
  @spec list(keyword()) :: [Computer.t()]
  def list(opts \\ []) when is_list(opts) do
    case fetch(opts) do
      {:ok, computers} ->
        computers

      {:error, reason} ->
        Logger.warning("the home's computers could not be listed: #{inspect(reason)}")
        []
    end
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
  Whether a turn can see the home's computers (M97 §6.5): an owner's turn
  (`:trust`, `:operator` when not given; a run's is `turn_trust/1`), where
  Always On is offered, on an engine booted as the primary. Every check is
  this engine's own, made before the link is asked, so a turn that cannot see
  computers never reaches it. The one rule for `prompt_section/1`, the
  `computer` argument (`Computers.Argument`) and where a call runs
  (`Computers.Choice`).
  """
  @spec visible?(keyword()) :: boolean()
  def visible?(opts) when is_list(opts),
    do: Keyword.get(opts, :trust, :operator) == :operator and always_on?(opts) and primary?(opts)

  @doc """
  The trust `visible?/1` reads for the run whose loop context is `context`:
  `:operator` only on the owner's own turn. Its person is the owner
  (`source_trust`), it runs at the owner's trust
  (`Capabilities.Registry.run_trust/1`, so a plugin
  skill's worker, which runs at guest under the owner's turn, does not), and
  it is no delegated worker (`Temporal.Access.worker?/1`: a skill's or a
  sub-agent's, at any trust). Anything else, a missing trust included, is
  `:guest`.
  """
  @spec turn_trust(map()) :: :operator | :guest
  def turn_trust(context) when is_map(context) do
    if Map.get(context, :source_trust) == :operator and
         CapabilityRegistry.run_trust(context) == :operator and not Access.worker?(context),
       do: :operator,
       else: :guest
  end

  @doc """
  The `## Computers` section (M97 §6.5), or nil: only on a turn that can see
  the computers (`visible?/1`) and when the home has one.
  """
  @spec prompt_section(keyword()) :: String.t() | nil
  def prompt_section(opts \\ []) when is_list(opts) do
    with true <- visible?(opts),
         [_ | _] = computers <- list(opts) do
      host = Keyword.get_lazy(opts, :host_facts, &HostFacts.current/0)
      Prompt.render(host, computers, Keyword.take(opts, [:personalization]))
    else
      _none -> nil
    end
  end

  @doc """
  Asks `computer` (a `Computer`, or its device id or name) to run `op` of
  the capability `module` with `args`, for the turn whose loop context is
  `context` (M97 §6.1): the caller blocks until the answer, at most the
  deadline and 2 s more. `{:ok, outcome}` when it ran (`Outcome` `ok`),
  else `{:error, outcome}`, whose `Outcome.sentence/2` the model reads. An
  effect is never sent twice by the link (`Computers.Invocation`).

  `opts`: `:deadline_ms` (30 s by default, 0 only for a long-lived op),
  `:part` (bytes, or `{bytes, mime}`, uploaded with the request) and
  `:on_part` (1-arity, told `%{received_bytes, size_bytes}` as the answer's
  part arrives), and `Computers.Invocation`'s seams. A caller stops what it
  asked by ending: its waiter has the computer cancel it
  (`Computers.Calls`).
  """
  @spec call(Computer.t() | String.t(), module(), String.t(), map(), map(), keyword()) ::
          {:ok, FermixCore.Computers.Outcome.t()} | {:error, FermixCore.Computers.Outcome.t()}
  def call(computer, module, op, args, context, opts \\ []),
    do: Invocation.call(computer, module, op, args, context, opts)

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

  defp joined({:ok, []}, _opts), do: {:ok, []}

  defp joined({:ok, rows}, opts) do
    live = Keyword.get_lazy(opts, :live, fn -> Registry.live() end)
    records = records(opts)
    version = Keyword.get_lazy(opts, :version, &BuildInfo.product_version/0)

    {:ok,
     rows
     |> Enum.map(&computer(&1, live[&1.device_id], Map.get(records, &1.device_id, %{}), version))
     |> Enum.sort_by(&String.downcase(&1.name))}
  end

  defp joined({:error, _reason} = error, _opts), do: error

  defp computer(row, live, record, version) do
    connected = row.connected and live != nil
    standing = standing(connected, live, record, version)

    %Computer{
      device_id: row.device_id,
      name: row.name,
      platform: Map.get(@platforms, row.platform),
      engine_version: Map.get(record, :engine_version),
      standing: standing,
      connected: row.connected,
      since: row.since,
      last_seen: latest(row.last_seen, Map.get(record, :seen_at)),
      path: if(connected, do: live.path),
      offers: if(Versions.served?(standing), do: offers(row.connected, live, record), else: []),
      backups: row.backups != false
    }
  end

  # Where the computer stands against this engine (M97 §3.4), decided once: a
  # connected one as its session's hello found it (the standing its chat and
  # history are served by), any other by the version it last said, and one
  # whose version is not known is not served. One not served offers nothing
  # until it updates.
  defp standing(true, %{standing: standing}, _record, _version), do: standing

  defp standing(_connected, _live, record, version),
    do: Versions.standing(Map.get(record, :engine_version), version)

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
