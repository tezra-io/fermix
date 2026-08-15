defmodule FermixCore.Temporal.DeliveryTest do
  use ExUnit.Case, async: true

  alias FermixCore.Temporal.Delivery

  defmodule DedupeAdapter do
    @moduledoc false

    def send_message(destination, text, opts) do
      key = Keyword.fetch!(opts, :proactive_key)

      destination
      |> String.to_existing_atom()
      |> Agent.get_and_update(&record_attempt(&1, key, text))
    end

    defp record_attempt(state, key, text) do
      attempts = state.attempts ++ [key]

      if MapSet.member?(state.seen, key) do
        {:ok, %{state | attempts: attempts}}
      else
        next = %{state | attempts: attempts, seen: MapSet.put(state.seen, key)}
        {:ok, %{next | fanouts: next.fanouts ++ [text]}}
      end
    end
  end

  test "reminder and follow-up retries use separate stable dedupe keys" do
    channel = :"temporal_delivery_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: channel,
      start:
        {Agent, :start_link,
         [fn -> %{seen: MapSet.new(), attempts: [], fanouts: []} end, [name: channel]]}
    })

    row = %{
      id: "reminder-42",
      delivery_platform: "mobile",
      delivery_destination: Atom.to_string(channel),
      delivery_thread_scope: "root"
    }

    opts = [adapter: DedupeAdapter]

    assert :ok = Delivery.attempt(row, "Reminder", 1_000, opts)
    assert :ok = Delivery.attempt(row, "Reminder", 1_000, opts)
    assert :ok = Delivery.attempt(row, "Follow-up", 1_000, opts, :followup)
    assert :ok = Delivery.attempt(row, "Follow-up", 1_000, opts, :followup)

    state = Agent.get(channel, & &1)

    assert state.attempts == [
             "temporal:reminder-42",
             "temporal:reminder-42",
             "temporal:reminder-42:followup",
             "temporal:reminder-42:followup"
           ]

    assert state.fanouts == ["Reminder", "Follow-up"]
  end
end
