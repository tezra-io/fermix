defmodule FermixChannels.Mobile.Push.WebPushLeg do
  @moduledoc """
  The Web Push half of `FermixChannels.Mobile.Push`: one push to each away
  phone that holds a Web Push subscription (M99).

  The home's key is loaded once and the plaintext (`WebPush.Payload`) built
  once for every phone; `WebPush` seals it to each phone's own key. When
  either cannot be had, every phone of the leg fails with that one typed
  reason, said once in the log.

  The phones are sent to concurrently, at most eight at a time, each send in
  a task of `FermixCore.TaskSupervisor` that is not linked to the caller. A
  send that has not finished within the deadline (90 s, past `WebPush.send/4`'s
  own worst case of about 75 s) is killed and counts as that phone's failure.

  A phone whose subscription the push service says is gone, or refuses this
  home's key for, has its registration cleared in the device store, said once
  in the log: the phone subscribes again at its next connection. Any other
  failure leaves the registration as it is.

  Each phone gets one `[:fermix, :channel, :push]` event, emitted from the
  caller once the leg ends. Failure reasons are typed classes: never a token,
  a key, an address or the service's words.
  """

  require Logger

  alias FermixChannels.Mobile.DeviceStore.Device
  alias FermixChannels.Mobile.WebPush
  alias FermixChannels.Mobile.WebPush.Key
  alias FermixChannels.Mobile.WebPush.Payload
  alias FermixChannels.Telemetry

  @max_concurrency 8
  @task_supervisor FermixCore.TaskSupervisor
  @cleared %{push_token: nil, push_service: nil, push_p256dh: nil, push_auth: nil}

  @typedoc "One phone that was not pushed, and why, as a typed class."
  @type failure :: %{device_id: String.t(), reason: term()}

  @typedoc """
  What the leg reaches: `key` loads the home's key, `send` is
  `WebPush.send/4`, `update_device` is `DeviceStore.update/2`, and
  `timeout_ms` is how long one send may take.
  """
  @type deps :: %{
          key: (-> {:ok, Key.t()} | {:error, term()}),
          send: (WebPush.subscription(), binary(), pos_integer(), keyword() ->
                   :ok | {:error, term()}),
          update_device: (String.t(), map() -> {:ok, Device.t()} | {:error, term()}),
          timeout_ms: pos_integer()
        }

  @doc "Sends `fields` to every phone in `phones`, as the module doc says."
  @spec deliver([Device.t(), ...], Payload.fields(), pos_integer(), deps()) ::
          {:ok, %{status: :sent, sent: pos_integer()}} | {:error, {:push_failed, [failure()]}}
  def deliver([_ | _] = phones, fields, ttl_s, %{timeout_ms: timeout_ms} = deps)
      when is_map(fields) and is_integer(ttl_s) and ttl_s > 0 and is_integer(timeout_ms) and
             timeout_ms > 0 do
    started = System.monotonic_time()

    with {:ok, key} <- load_key(deps, length(phones)),
         {:ok, plaintext} <- encode(fields, length(phones)) do
      phones
      |> send_all(plaintext, ttl_s, key, deps)
      |> Enum.map(&settle(&1, started, deps))
      |> summarize()
    else
      {:error, reason} -> fail_all(phones, reason, started)
    end
  end

  defp load_key(deps, count) do
    case deps.key.() do
      {:ok, %Key{} = key} ->
        {:ok, key}

      {:error, reason} ->
        Logger.error(
          "mobile Web Push has no key (#{inspect(reason)}); #{count} phone(s) not pushed"
        )

        {:error, {:web_push_key, class(reason)}}

      other ->
        Logger.error("mobile Web Push key loader answered #{inspect(other)}")
        {:error, {:web_push_key, :invalid_result}}
    end
  end

  defp encode(fields, count) do
    case Payload.encode(fields) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, reason} ->
        Logger.error(
          "mobile Web Push could not build its message (#{inspect(reason)}); " <>
            "#{count} phone(s) not pushed"
        )

        {:error, {:web_push_payload, reason}}
    end
  end

  # Bounded: `phones` is at most `Push.max_devices/0` long, and each task by
  # `timeout_ms`.
  defp send_all(phones, plaintext, ttl_s, key, deps) do
    @task_supervisor
    |> Task.Supervisor.async_stream_nolink(
      phones,
      fn phone -> timed_send(phone, plaintext, ttl_s, key, deps.send) end,
      max_concurrency: @max_concurrency,
      timeout: deps.timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(phones)
  end

  defp timed_send(phone, plaintext, ttl_s, key, send) do
    started = System.monotonic_time()
    result = send.(subscription(phone), plaintext, ttl_s, key: key)
    {result, elapsed_us(started)}
  end

  defp subscription(%Device{} = phone) do
    %{
      service: phone.push_service,
      token: phone.push_token,
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
    Logger.error("mobile Web Push sender answered #{inspect(other)} for #{phone.device_id}")
    Telemetry.emit_push(:mobile, :failed, duration_us)
    %{device_id: phone.device_id, reason: :invalid_result}
  end

  defp settle({{:exit, :timeout}, phone}, started, _deps) do
    Logger.error("mobile Web Push to #{phone.device_id} did not finish in time; it was stopped")
    Telemetry.emit_push(:mobile, :failed, elapsed_us(started))
    %{device_id: phone.device_id, reason: :timeout}
  end

  defp settle({{:exit, reason}, phone}, started, _deps) do
    Logger.error("mobile Web Push to #{phone.device_id} exited: #{inspect(class(reason))}")
    Telemetry.emit_push(:mobile, :failed, elapsed_us(started))
    %{device_id: phone.device_id, reason: :crashed}
  end

  defp maybe_drop(reason, phone, deps) when reason in [:gone, :sender_refused] do
    why = drop_sentence(reason)

    case deps.update_device.(phone.device_id, @cleared) do
      {:ok, _device} ->
        Logger.warning(
          "mobile Web Push dropped #{phone.device_id}'s subscription: #{why}; " <>
            "the phone subscribes again at its next connection"
        )

      {:error, failure} ->
        Logger.error(
          "mobile Web Push could not drop #{phone.device_id}'s subscription (#{why}): " <>
            inspect(failure)
        )
    end
  end

  defp maybe_drop(_reason, _phone, _deps), do: :ok

  defp drop_sentence(:gone), do: "the push service says it no longer exists"
  defp drop_sentence(:sender_refused), do: "the push service refused this home's key for it"

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

  # The service's own words stay in `WebPush`'s log line, never in a reason.
  defp reason_class({:refused, status, _excerpt}), do: {:refused, status}
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
