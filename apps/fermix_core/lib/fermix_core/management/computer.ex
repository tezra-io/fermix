defmodule FermixCore.Management.Computer do
  @moduledoc """
  What Fermix on its server did on this computer (M97 §6.3, §7.4): the
  management method `computer.journal.list`, the owner's read of this
  computer's own journal (`FermixCore.Computers.Journal`), which the app
  shows as "What Fermix did on this computer".

  Device-class (`Management.Placement`): answered on the computer that
  asks, never forwarded, and a server refuses a forwarded one. A computer
  that never moved, and a server, answer an empty list.

  Params: `limit` (1 to #{200}, default #{50}) and `before` (an invocation's
  id: only older ones). Answers `{entries, more}`, the newest first, each
  `{id, at, finished_at, capability, op, target, origin, status, refusal,
  result_bytes, duration_ms}` (null where it does not apply yet: a request
  still running has no `finished_at` and no `status`). Seams in `opts`:
  `:home`.
  """

  require Logger

  alias FermixCore.Computers.Journal
  alias FermixCore.Management.Protocol
  alias FermixCore.Setup.ConfigStore

  @params ~w(limit before)
  @default_limit 50
  @max_limit 200
  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
  @unreadable "This computer's record of what Fermix did here could not be read. See the " <>
                "daemon log."

  @doc "`computer.journal.list` (the moduledoc)."
  @spec journal_list(map(), keyword()) :: Protocol.route_result()
  def journal_list(params, opts \\ []) when is_map(params) and is_list(opts) do
    with :ok <- known_params(params),
         {:ok, limit} <- limit(Map.get(params, "limit", @default_limit)),
         {:ok, before} <- before(Map.get(params, "before")) do
      home = Keyword.get_lazy(opts, :home, &ConfigStore.fermix_home/0)
      listed(Journal.list(Journal.dir(home), limit: limit, before: before))
    end
  end

  @doc "Every sentence this method says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences, do: [@unreadable]

  defp listed({:ok, %{entries: entries, more: more}}),
    do: {:ok, %{"entries" => Enum.map(entries, &view/1), "more" => more}}

  defp listed({:error, reason}) do
    Logger.error("the invocation journal could not be read: #{inspect(reason)}")
    {:error, :unavailable, %{"sentence" => @unreadable}}
  end

  defp view(entry) do
    %{
      "id" => entry.id,
      "at" => entry.at,
      "finished_at" => entry.finished_at,
      "capability" => entry.capability,
      "op" => entry.op,
      "target" => entry.target,
      "origin" => entry.origin,
      "status" => entry.status,
      "refusal" => entry.refusal,
      "result_bytes" => entry.result_bytes,
      "duration_ms" => entry.duration_ms
    }
  end

  defp known_params(params) do
    case Enum.find(Map.keys(params), &(&1 not in @params)) do
      nil -> :ok
      field -> {:error, :invalid_params, %{"field" => field}}
    end
  end

  defp limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: {:ok, limit}
  defp limit(_limit), do: {:error, :invalid_params, %{"field" => "limit"}}

  defp before(nil), do: {:ok, nil}

  defp before(id) when is_binary(id) do
    if Regex.match?(@id, id),
      do: {:ok, id},
      else: {:error, :invalid_params, %{"field" => "before"}}
  end

  defp before(_id), do: {:error, :invalid_params, %{"field" => "before"}}
end
