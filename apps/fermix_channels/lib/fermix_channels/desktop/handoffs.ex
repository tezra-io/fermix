defmodule FermixChannels.Desktop.Handoffs do
  @moduledoc """
  The `handoff` family of a connected desktop on the primary
  (`Desktop.Family`, M75 D18, B10): the browser hand-offs the owner starts on
  that desktop, and its wipes.

  `handoff_begin` names a hand-off (its sites, its expiry and how many
  cookies follow) and `handoff_chunk` carries the cookies, put back together
  by the peer. The cookies are checked against what the hand-off named
  (`FermixCore.Browser.Handoff.Cookies.decode/3`: exactly that many, each for
  one of its sites), then stored in the owner profile and recorded
  (`FermixCore.Browser.Handoff.store/2`) in a task of its own, since it may
  start Chrome. The desktop is answered `handoff_stored` (how many, until
  when) or `handoff_refused` with the sentence the owner reads. At most 4
  hand-offs wait for their cookies at once.

  `handoff_wipe` deletes the hand-offs of the sites it names, or every one
  (`FermixCore.Browser.Handoff.wipe/2`), in a task of its own, and answers
  the desktop under the wipe's `handoff_id`: `handoff_wiped` with how many
  cookies it deleted, or `handoff_refused` with the sentence the owner reads.

  Test seams, the family's options (`Desktop.Peer`'s `{module, options}`):
  `:device_name`, `:send` (in place of `Desktop.Peer.send/4`), `:store`,
  `:wipe`, `:task_supervisor`.
  """

  @behaviour FermixChannels.Desktop.Family

  require Logger

  alias FermixChannels.Desktop.Peer
  alias FermixChannels.Mobile.DeviceStore
  alias FermixCore.Browser.ChromeLauncher
  alias FermixCore.Browser.Error, as: BrowserError
  alias FermixCore.Browser.Handoff
  alias FermixCore.Browser.Handoff.Cookies

  @max_pending 4
  @peers FermixChannels.Desktop.Peers

  @impl true
  def init(context) do
    options = Map.get(context, :options, [])

    {:ok,
     %{
       device_id: context.device_id,
       peers: Map.get(context, :registry) || @peers,
       device_name: Keyword.get(options, :device_name),
       send: Keyword.get(options, :send, &Peer.send/4),
       store: Keyword.get(options, :store, &Handoff.store/2),
       wipe: Keyword.get(options, :wipe, &Handoff.wipe/2),
       task_supervisor: Keyword.get(options, :task_supervisor, FermixCore.TaskSupervisor),
       pending: %{}
     }}
  end

  @impl true
  def handle_event("handoff_begin", %{"handoff_id" => id} = fields, _payload, state) do
    cond do
      map_size(state.pending) >= @max_pending ->
        refuse(state, id, "The server is storing other hand-offs. Try again in a moment.")
        {:ok, state}

      fields["count"] > Cookies.max_cookies() ->
        refuse(state, id, "A hand-off carries at most #{Cookies.max_cookies()} cookies.")
        {:ok, state}

      true ->
        {:ok, expires_at, _offset} = DateTime.from_iso8601(fields["expires_at"])
        pending = %{sites: fields["sites"], expires_at: expires_at, count: fields["count"]}
        {:ok, put_in(state.pending[id], pending)}
    end
  end

  def handle_event("handoff_chunk", %{"handoff_id" => id}, payload, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        refuse(state, id, "The server has no hand-off by that id. Run the hand-off again.")
        {:ok, state}

      {handoff, pending} ->
        receive_cookies(state, id, handoff, payload)
        {:ok, %{state | pending: pending}}
    end
  end

  def handle_event("handoff_wipe", %{"handoff_id" => id} = fields, _payload, state) do
    sites = Map.get(fields, "sites", :all)
    in_task(state, fn -> wiped(state, id, state.wipe.(sites, []), sites) end)
    {:ok, state}
  end

  @impl true
  def handle_info(message, state) do
    Logger.warning("desktop hand-off: unexpected message #{inspect(message)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp receive_cookies(state, id, handoff, payload) do
    case Cookies.decode(payload, handoff.sites, handoff.count) do
      {:ok, cookies} ->
        stored = %{
          handoff_id: id,
          from: name(state),
          sites: handoff.sites,
          expires_at: handoff.expires_at,
          cookies: cookies
        }

        in_task(state, fn -> answer(state, id, state.store.(stored, [])) end)

      {:error, reason} ->
        Logger.warning("desktop hand-off: #{id} refused: #{inspect(reason)}")

        refuse(
          state,
          id,
          "The hand-off's cookies did not match what it named, so the server stored nothing."
        )
    end
  end

  defp answer(state, id, {:ok, %{cookies: count, expires_at: expires_at}}) do
    event = %{
      "t" => "handoff_stored",
      "handoff_id" => id,
      "cookies" => count,
      "expires_at" => expires_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    tell(state, event)
  end

  defp answer(state, id, {:error, reason}) do
    Logger.error("desktop hand-off: #{id} was not stored: #{inspect(reason)}")
    refuse(state, id, store_sentence(reason))
  end

  defp store_sentence({:invalid_expiry, _at}),
    do: "The hand-off's expiry is not within the next 30 days, so the server stored nothing."

  defp store_sentence({:set_cookies, :profile_not_managed}),
    do: "The server's browser profile is not one Fermix runs Chrome in, so it stored nothing."

  defp store_sentence({:set_cookies, %BrowserError{} = error}),
    do: "The server stored nothing: " <> ChromeLauncher.sentence({:error, error})

  defp store_sentence(_reason),
    do: "The server could not store the cookies. Its daemon log says why."

  defp wiped(state, id, {:ok, %{cookies: count}}, sites) do
    Logger.info("desktop hand-off: wiped #{count} cookies of #{inspect(sites)}")
    tell(state, %{"t" => "handoff_wiped", "handoff_id" => id, "cookies" => count})
  end

  defp wiped(state, id, {:error, reason}, sites) do
    Logger.error("desktop hand-off: the wipe of #{inspect(sites)} failed: #{inspect(reason)}")
    refuse(state, id, "The server could not wipe the hand-offs. Its daemon log says why.")
  end

  defp refuse(state, id, sentence),
    do: tell(state, %{"t" => "handoff_refused", "handoff_id" => id, "sentence" => sentence})

  defp tell(state, %{"t" => type} = event) do
    case state.send.(state.device_id, event, <<>>, registry: state.peers) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("desktop hand-off: #{type} not sent: #{inspect(reason)}")
    end
  end

  defp in_task(state, fun) do
    case Task.Supervisor.start_child(state.task_supervisor, fun) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.error("desktop hand-off: no task: #{inspect(reason)}")
    end
  end

  # The desktop's name, read from its row when the ledger needs it. A row
  # that cannot be read is logged, and the ledger names the desktop's id.
  defp name(%{device_name: name}) when is_binary(name), do: name

  defp name(%{device_id: device_id}) do
    case DeviceStore.fetch(DeviceStore, device_id) do
      {:ok, %{name: name}} ->
        name

      {:error, reason} ->
        Logger.error("desktop hand-off: desktop #{device_id}'s row: #{inspect(reason)}")
        device_id
    end
  end
end
