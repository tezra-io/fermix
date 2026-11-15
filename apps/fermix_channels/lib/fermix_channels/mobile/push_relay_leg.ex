defmodule FermixChannels.Mobile.Push.RelayLeg do
  @moduledoc """
  The relay half of `FermixChannels.Mobile.Push`: one push to each away
  phone that holds a subscription, through Fermix's push relay (M99 §14).

  The plaintext (`WebPush.Payload`) is built once for every phone;
  `PushRelay` seals it to each phone's own key. When it cannot be built,
  every phone of the leg fails with that one typed reason, said once in the
  log. There is no key to load: the home holds none.

  The phones are sent to concurrently, at most eight at a time, each send in
  a task of `FermixCore.TaskSupervisor` that is not linked to the caller. A
  send that has not finished within the deadline (90 s, past
  `PushRelay.send/4`'s own worst case of about 75 s) is killed and counts as
  that phone's failure.

  A phone whose address the relay says is gone has its registration cleared
  in the device store, said once in the log: the phone hands over its address
  again at its next connection. Nothing else clears it.

  Once every phone has settled, the leg tells the phone channel what it
  learned of the relay (`report`): `:reached` when the relay accepted any
  push, `{:unreachable, class}` when it accepted none and at least one ended
  `unavailable` after its tries, and nothing otherwise.

  Each phone gets one `[:fermix, :channel, :push]` event, emitted from the
  caller once the leg ends. Failure reasons are typed classes: never an
  address, a key or a word of an answer the relay does not have.
  """

  require Logger

  alias FermixChannels.Mobile.DeviceStore.Device
  alias FermixChannels.Mobile.PushRelay
  alias FermixChannels.Mobile.WebPush.Payload
  alias FermixChannels.Telemetry

  @max_concurrency 8
  @task_supervisor FermixCore.TaskSupervisor
  @cleared %{push_token: nil, push_service: nil, push_p256dh: nil, push_auth: nil}

  @typedoc "One phone that was not pushed, and why, as a typed class."
  @type failure :: %{device_id: String.t(), reason: term()}

  @typedoc """
  What the relay's answers said of it in one leg: it accepted a push, or it
  could not be reached, by the class of the last failure.
  """
  @type relay_outcome :: :reached | {:unreachable, atom()}

  @typedoc """
  What the leg reaches: `send` is `PushRelay.send/4`, `update_device` is
  `DeviceStore.update/2`, `report` takes the leg's `relay_outcome()`, and
  `timeout_ms` is how long one send may take.
  """
  @type deps :: %{
          send: (PushRelay.subscription(), binary(), pos_integer(), keyword() ->
                   :ok | {:error, term()}),
          update_device: (String.t(), map() -> {:ok, Device.t()} | {:error, term()}),
          report: (relay_outcome() -> :ok | {:error, term()}),
          timeout_ms: pos_integer()
        }

  @doc "Sends `fields` to every phone in `phones`, as the module doc says."
  @spec deliver([Device.t(), ...], Payload.fields(), pos_integer(), deps()) ::
          {:ok, %{status: :sent, sent: pos_integer()}} | {:error, {:push_failed, [failure()]}}
  def deliver([_ | _] = phones, fields, ttl_s, %{timeout_ms: timeout_ms} = deps)
      when is_map(fields) and is_integer(ttl_s) and ttl_s > 0 and is_integer(timeout_ms) and
             timeout_ms > 0 do
    started = System.monotonic_time()

    case encode(fields, length(phones)) do
      {:ok, plaintext} ->
        settled =
          phones
          |> send_all(plaintext, ttl_s, deps)
          |> Enum.map(&settle(&1, started, deps))

        report(settled, deps)
        summarize(settled)

      {:error, reason} ->
        fail_all(phones, reason, started)
    end
  end

  defp encode(fields, count) do
    case Payload.encode(fields) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, reason} ->
        Logger.error(
          "mobile push could not build its message (#{inspect(reason)}); " <>
            "#{count} phone(s) not pushed"
        )

        {:error, {:push_payload, reason}}
    end
  end

  # Bounded: `phones` is at most `Push.max_devices/0` long, and each task by
  # `timeout_ms`.
  defp send_all(phones, plaintext, ttl_s, deps) do
    @task_supervisor
    |> Task.Supervisor.async_stream_nolink(
      phones,
      fn phone -> timed_send(phone, plaintext, ttl_s, deps.send) end,
      max_concurrency: @max_concurrency,
      timeout: deps.timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(phones)
  end

  defp timed_send(phone, plaintext, ttl_s, send) do
    started = System.monotonic_time()
    result = send.(subscription(phone), plaintext, ttl_s, [])
    {result, elapsed_us(started)}
  end

  defp subscription(%Device{} = phone) do
    %{
      service: phone.push_service,
      address: phone.push_token,
      p256dh: phone.push_p256dh,
      auth: phone.push_auth
    }
  end

  defp settle({{:ok, {:ok, duration_us}}, _phone}, _started, _deps) do
    Telemetry.emit_push(:mobile, :sent, duration_us)
    :sent
  end

  defp settle({{:ok, {{:error, reason}, duration_us}}, phone}, _started, deps) do
    Telemetry.emit_push(:mobile, :failed, duration_us)
    maybe_drop(reason, phone, deps)
    %{device_id: phone.device_id, reason: reason_class(reason)}
  end

  defp settle({{:ok, {other, duration_us}}, phone}, _started, _deps) do
    Logger.error("mobile push sender answered #{inspect(other)} for #{phone.device_id}")
    Telemetry.emit_push(:mobile, :failed, duration_us)
    %{device_id: phone.device_id, reason: :invalid_result}
  end

  defp settle({{:exit, :timeout}, phone}, started, _deps) do
    Logger.error("mobile push to #{phone.device_id} did not finish in time; it was stopped")
    Telemetry.emit_push(:mobile, :failed, elapsed_us(started))
    %{device_id: phone.device_id, reason: :timeout}
  end

  defp settle({{:exit, reason}, phone}, started, _deps) do
    Logger.error("mobile push to #{phone.device_id} exited: #{inspect(class(reason))}")
    Telemetry.emit_push(:mobile, :failed, elapsed_us(started))
    %{device_id: phone.device_id, reason: :crashed}
  end

  defp maybe_drop(:gone, phone, deps) do
    case deps.update_device.(phone.device_id, @cleared) do
      {:ok, _device} ->
        Logger.warning(
          "mobile push dropped #{phone.device_id}'s subscription: the relay says Google no " <>
            "longer knows its address; the phone hands over its address again at its next " <>
            "connection"
        )

      {:error, failure} ->
        Logger.error(
          "mobile push could not drop #{phone.device_id}'s subscription, whose address " <>
            "the relay says is gone: " <> inspect(failure)
        )
    end
  end

  defp maybe_drop(_reason, _phone, _deps), do: :ok

  # What the leg learned of the relay: any accepted push reached it, and with
  # none accepted, a push that ran out of tries names the last failure's class.
  defp report(settled, deps) do
    case relay_outcome(settled) do
      nil -> :ok
      outcome -> report_outcome(deps.report, outcome)
    end
  end

  defp relay_outcome(settled) do
    if :sent in settled do
      :reached
    else
      Enum.find_value(settled, fn
        %{reason: {:unavailable, last}} -> {:unreachable, unreachable_class(last)}
        _other -> nil
      end)
    end
  end

  defp unreachable_class({:relay, word}), do: word
  defp unreachable_class({:http, _status}), do: :gateway
  defp unreachable_class({:transport, reason}), do: reason

  defp report_outcome(report, outcome) do
    case report.(outcome) do
      :ok ->
        :ok

      other ->
        Logger.error(
          "mobile push could not record what the relay said (#{inspect(outcome)}): " <>
            inspect(other)
        )
    end
  end

  defp summarize(outcomes) do
    case Enum.reject(outcomes, &(&1 == :sent)) do
      [] -> {:ok, %{status: :sent, sent: length(outcomes)}}
      failures -> {:error, {:push_failed, failures}}
    end
  end

  defp fail_all(phones, reason, started) do
    duration_us = elapsed_us(started)
    Enum.each(phones, fn _phone -> Telemetry.emit_push(:mobile, :failed, duration_us) end)
    {:error, {:push_failed, Enum.map(phones, &%{device_id: &1.device_id, reason: reason})}}
  end

  # Every reason `PushRelay` answers is already typed and carries no address.
  defp reason_class(:gone), do: :gone
  defp reason_class({:rejected, word}) when is_atom(word), do: {:rejected, word}
  defp reason_class({:refused, status}) when is_integer(status), do: {:refused, status}
  defp reason_class({:unavailable, _last} = reason), do: reason
  defp reason_class({:invalid, reason}), do: {:invalid, class(reason)}
  defp reason_class(reason), do: class(reason)

  defp class(reason) when is_atom(reason), do: reason
  defp class(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  defp class(_reason), do: :unknown

  defp elapsed_us(started) do
    (System.monotonic_time() - started)
    |> System.convert_time_unit(:native, :microsecond)
    |> max(0)
  end
end
