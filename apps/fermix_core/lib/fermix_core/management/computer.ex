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
  `{id, at, finished_at, capability, capability_label, op, op_label, target,
  origin, status, refusal, result_bytes, duration_ms}` (null where it does
  not apply yet: a request still running has no `finished_at` and no
  `status`). The two labels are the owner's words for the capability and
  the op, from the capability's own module in this engine's registry
  (`:computer_capabilities`, `FermixChannels.Desktop.Invoke`, injected by
  module as `Computers.Transport` is), each null for an id this engine has
  no words for. Seams in `opts`: `:home`.

  `computer.screen.stop` (M97 §7.4) is the Stop beside the mark an app draws
  while Fermix on its server controls this computer's screen (`home.status`'s
  `screen`): the server's hold ends at once, held input is released and the
  server hears that the person here stopped it (`ComputerUse.Seat.stop/1`).
  No params; answers `{stopped}`, false when nothing held the screen. Device-
  class as well. Seam: `:seat` (the seat's name).
  """

  require Logger

  alias FermixCore.Computers.Capability
  alias FermixCore.Computers.Journal
  alias FermixCore.ComputerUse.Seat
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

  @doc "`computer.screen.stop` (the moduledoc)."
  @spec screen_stop(map(), keyword()) :: Protocol.route_result()
  def screen_stop(params, opts \\ []) when is_map(params) and is_list(opts) do
    with :ok <- no_params(params) do
      {:ok, %{"stopped" => stopped?(Keyword.get(opts, :seat, Seat.name()))}}
    end
  end

  defp no_params(params) do
    case Map.keys(params) do
      [] -> :ok
      [field | _more] -> {:error, :invalid_params, %{"field" => field}}
    end
  end

  # A computer that runs no seat holds no screen for its server.
  defp stopped?(seat) do
    Seat.stop(seat) == :stopped
  catch
    :exit, {:noproc, _call} -> false
  end

  @doc "Every sentence this method says, for the copy rules."
  @spec sentences() :: [String.t()]
  def sentences, do: [@unreadable]

  defp listed({:ok, %{entries: entries, more: more}}) do
    capabilities = Application.fetch_env!(:fermix_core, :computer_capabilities).capabilities()
    {:ok, %{"entries" => Enum.map(entries, &view(&1, capabilities)), "more" => more}}
  end

  defp listed({:error, reason}) do
    Logger.error("the invocation journal could not be read: #{inspect(reason)}")
    {:error, :unavailable, %{"sentence" => @unreadable}}
  end

  defp view(entry, capabilities) do
    {capability_label, op_label} = labels(capabilities, entry.capability, entry.op)

    %{
      "id" => entry.id,
      "at" => entry.at,
      "finished_at" => entry.finished_at,
      "capability" => entry.capability,
      "capability_label" => capability_label,
      "op" => entry.op,
      "op_label" => op_label,
      "target" => entry.target,
      "origin" => entry.origin,
      "status" => entry.status,
      "refusal" => entry.refusal,
      "result_bytes" => entry.result_bytes,
      "duration_ms" => entry.duration_ms
    }
  end

  # The owner's words for an entry's capability and op, from the capability's
  # own module (`Computers.Capability`'s `label/0` and `op_label/1`), each nil
  # where this engine has none for its id: an older journal row may name a
  # capability or an op this engine no longer has.
  defp labels(capabilities, capability, op) do
    module = Map.get(capabilities, capability)

    if worded?(module),
      do: {module.label(), op_label(module, op)},
      else: {nil, nil}
  end

  defp worded?(nil), do: false

  defp worded?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :label, 0) and
      function_exported?(module, :op_label, 1)
  end

  defp op_label(module, op) do
    if is_binary(op) and Capability.runs?(module, op), do: module.op_label(op)
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
