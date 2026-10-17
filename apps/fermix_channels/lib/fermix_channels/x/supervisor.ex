defmodule FermixChannels.X.Supervisor do
  @moduledoc """
  The X channel's transport: `X.Pump`, which owns the assignments, and
  `X.Client`, which dials Fermix Connect, supervised `:one_for_one`.

  It starts only for an installation that can serve the channel, and refuses
  otherwise with one error line naming why, starting nothing (`:ignore`): the
  channel is enabled but this Fermix is not paired with Connect, its pairing
  record or instance key is unusable, the memory store that holds its
  assignments is not running, or the outbound proxy would carry its socket,
  which cannot tunnel (`:proxy_unsupported_transport`). Each of those changes
  only when a setting or the pairing does, so trying again on its own would
  repeat the line and nothing else.

  `opts`: `:pairing` (the `X.Pairing` options, `root:` in tests), `:pump` and
  `:client` (each child's own options), `:egress`, `:memory` (the store check,
  `fn -> :ok | {:error, :memory_unavailable} end`) and `:name`.

  The subtree is registered under the channels application's supervisor when
  the channel is on at boot. Pairing starts it there again (`start_registered/1`)
  and unpairing stops it (`stop_registered/1`), so neither waits for a restart.
  """

  use Supervisor

  require Logger

  alias FermixChannels.X.Client
  alias FermixChannels.X.Pairing
  alias FermixChannels.X.Pump
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo
  alias FermixCore.Net.Egress

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    case admit(opts) do
      {:ok, record} ->
        Supervisor.init(children(record, opts), strategy: :one_for_one)

      {:error, refusal} ->
        Logger.error(refusal_sentence(refusal))
        :ignore
    end
  end

  @doc """
  Whether this installation can serve the channel: its pairing record, the
  instance key that record names, a running memory store and a direct route
  to Connect.
  """
  @spec admit(keyword()) :: {:ok, Pairing.t()} | {:error, term()}
  def admit(opts) when is_list(opts) do
    with {:ok, record, _public_key} <- paired(Keyword.get(opts, :pairing, [])),
         :ok <- Keyword.get(opts, :memory, &memory_running/0).(),
         :ok <- direct_route(record, opts) do
      {:ok, record}
    end
  end

  @doc """
  The pairing record and the instance key it names: `{:error, :unpaired}`
  with no record, `{:invalid_record, reason}` for one that is unusable, and
  `{:instance_key, reason}` for a key that is missing, unreadable or not the
  one the record names.
  """
  @spec paired(keyword()) :: {:ok, Pairing.t(), Pairing.public_key()} | {:error, term()}
  def paired(pairing) when is_list(pairing) do
    with {:ok, record} <- Pairing.load(pairing),
         {:ok, public_key} <- instance_key(pairing),
         :ok <- same_key(Pairing.key_id(public_key), record.key_id) do
      {:ok, record, public_key}
    end
  end

  @doc """
  Starts the registered subtree again once a pairing exists, while the switch
  is on: `{:ok, :started}`, `{:ok, :not_started}` (the admission check refused
  it again, and said why), or `{:ok, :not_registered}` when the channel was
  off at boot, so a restart is what starts it. `:parent` and `:config` are
  seams.
  """
  @spec start_registered(keyword()) ::
          {:ok, :started | :not_started | :not_registered | :switched_off} | {:error, term()}
  def start_registered(opts \\ []) when is_list(opts) do
    config =
      Keyword.get_lazy(opts, :config, fn -> Application.get_env(:fermix_channels, :x, []) end)

    if Keyword.get(config, :enabled, false) == true,
      do: restart_child(parent(opts)),
      else: {:ok, :switched_off}
  end

  @doc "Stops the registered subtree, which stays registered; absent is not an error."
  @spec stop_registered(keyword()) :: :ok
  def stop_registered(opts \\ []) when is_list(opts) do
    case Supervisor.terminate_child(parent(opts), __MODULE__) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp restart_child(parent) do
    case Supervisor.restart_child(parent, __MODULE__) do
      {:ok, pid} when is_pid(pid) -> {:ok, :started}
      {:ok, :undefined} -> {:ok, :not_started}
      {:error, :running} -> {:ok, :started}
      {:error, :not_found} -> {:ok, :not_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parent(opts), do: Keyword.get(opts, :parent, FermixChannels.Supervisor)

  defp children(record, opts) do
    pairing = Keyword.get(opts, :pairing, [])
    client_opts = Keyword.merge([pairing: pairing], Keyword.get(opts, :client, []))

    [
      {Pump, Keyword.merge([record: record], Keyword.get(opts, :pump, []))},
      {Client, {record, client_opts}}
    ]
  end

  defp instance_key(pairing) do
    case Pairing.public_key(pairing) do
      {:ok, public_key} -> {:ok, public_key}
      {:error, reason} -> {:error, {:instance_key, reason}}
    end
  end

  defp same_key(key_id, key_id), do: :ok
  defp same_key(_found, _paired), do: {:error, {:instance_key, :does_not_match_pairing}}

  defp memory_running do
    case Repo.enabled_server(MemoryConfig.repo_server()) do
      nil -> {:error, :memory_unavailable}
      _server -> :ok
    end
  end

  defp direct_route(record, opts) do
    egress = Keyword.get_lazy(opts, :egress, &Egress.active/0)
    Egress.ensure_direct(Client.url(record), egress)
  end

  defp refusal_sentence(:unpaired), do: "x is enabled but this Fermix is not paired with Connect"

  defp refusal_sentence({:invalid_record, reason}),
    do: "x is enabled but its Connect pairing record is unusable: #{inspect(reason)}"

  defp refusal_sentence({:instance_key, reason}),
    do: "x is enabled but its Connect instance key is unusable: #{inspect(reason)}"

  defp refusal_sentence(:memory_unavailable),
    do: "x is enabled but the memory store that holds its assignments is not running"

  defp refusal_sentence(:proxy_unsupported_transport),
    do:
      "x is enabled but its Connect socket cannot use the outbound proxy " <>
        "(:proxy_unsupported_transport); list the Connect host in " <>
        "[fermix_core.network] proxy_bypass if this machine reaches it directly"
end
