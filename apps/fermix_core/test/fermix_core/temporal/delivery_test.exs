defmodule FermixCore.Temporal.DeliveryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias FermixCore.Temporal.Delivery

  defmodule OptsAdapter do
    @moduledoc false

    # Hands the send options it was given to the test registered under the
    # destination's name, from the watchdog's own send process.
    def send_message(destination, _text, opts) do
      send(String.to_existing_atom(destination), {:send_opts, opts})
      :ok
    end
  end

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

  test "a reminder's retries share one stable dedupe key" do
    channel = :"temporal_delivery_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: channel,
      start:
        {Agent, :start_link,
         [fn -> %{seen: MapSet.new(), attempts: [], fanouts: []} end, [name: channel]]}
    })

    row = %{
      id: "reminder-42",
      payload: %{"title" => "Reminder"},
      delivery_platform: "mobile",
      delivery_destination: Atom.to_string(channel),
      delivery_thread_scope: "root"
    }

    opts = [adapter: DedupeAdapter]

    assert :ok = Delivery.attempt(row, "Reminder", 1_000, opts)
    assert :ok = Delivery.attempt(row, "Reminder", 1_000, opts)

    state = Agent.get(channel, & &1)

    assert state.attempts == ["temporal:reminder-42", "temporal:reminder-42"]
    assert state.fanouts == ["Reminder"]
  end

  defp recipient! do
    name = :"temporal_delivery_opts_#{System.unique_integer([:positive])}"
    Process.register(self(), name)
    Atom.to_string(name)
  end

  # M76 §4.6: a notification's summary is the event's title and its Snooze
  # names the reminder, so every attempt hands the adapter both, on every
  # platform: no adapter validates the options it is given.
  test "every attempt carries the event's title and the reminder's id beside its thread and key" do
    destination = recipient!()

    row = %{
      id: "rem_42",
      payload: %{"title" => "Tea"},
      delivery_platform: "telegram",
      delivery_destination: destination,
      delivery_thread_scope: "17"
    }

    assert :ok = Delivery.attempt(row, "Reminder: Tea", 1_000, adapter: OptsAdapter)
    assert_receive {:send_opts, opts}

    assert Enum.sort(opts) == [
             message_thread_id: 17,
             proactive_key: "temporal:rem_42",
             reminder_id: "rem_42",
             title: "Tea"
           ]

    computer = %{row | delivery_platform: "computer", delivery_thread_scope: "root"}

    assert :ok = Delivery.attempt(computer, "Later", 1_000, adapter: OptsAdapter)
    assert_receive {:send_opts, computer_opts}

    assert Enum.sort(computer_opts) == [
             proactive_key: "temporal:rem_42",
             reminder_id: "rem_42",
             title: "Tea"
           ]
  end

  test "a row that carries no event title fails terminally before any send" do
    destination = recipient!()

    row = %{
      id: "rem_43",
      payload: %{},
      delivery_platform: "computer",
      delivery_destination: destination,
      delivery_thread_scope: "root"
    }

    log =
      capture_log(fn ->
        assert {:error, {:permanent, :malformed_request}} =
                 Delivery.attempt(row, "Reminder", 1_000, adapter: OptsAdapter)
      end)

    assert log =~ "no event title"
    refute_received {:send_opts, _opts}
  end
end
