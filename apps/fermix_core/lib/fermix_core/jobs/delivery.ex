defmodule FermixCore.Jobs.Delivery do
  @moduledoc """
  Scheduler-owned delivery for completed scheduled job runs.

  The core app stays decoupled from channel implementations by resolving channel
  modules from configuration or test injection and calling their `send_message/3`
  contract dynamically.
  """

  alias FermixCore.Net.HttpClient

  @type delivery_result :: {:ok, String.t()} | {:error, term()}

  @default_timeout_ms 60_000
  @default_delivery_attempts 3
  @default_delivery_backoff_ms 1_000

  @spec initial_status(map(), String.t() | nil) :: String.t()
  def initial_status(job, text) do
    cond do
      delivery_mode(job) == "none" -> "none"
      silent?(text, Map.get(job, :silent_marker)) -> "skipped"
      true -> "pending"
    end
  end

  @spec deliver(map(), String.t() | nil, keyword()) :: delivery_result()
  def deliver(job, text, opts \\ []) do
    cond do
      delivery_mode(job) == "none" ->
        {:ok, "none"}

      silent?(text, Map.get(job, :silent_marker)) ->
        {:ok, "skipped"}

      delivery_mode(job) == "local" ->
        {:ok, "sent"}

      delivery_mode(job) in ["origin", "channel"] ->
        deliver_to_channel(job, text || "", opts)

      true ->
        {:error, {:unsupported_delivery_mode, delivery_mode(job)}}
    end
  end

  @spec deliver_with_timeout(map(), String.t() | nil, keyword()) :: delivery_result()
  def deliver_with_timeout(job, text, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    cond do
      immediate_delivery?(job, text) ->
        deliver(job, text, opts)

      bounded_timeout?(timeout_ms) ->
        deliver_with_timeout(job, text, opts, timeout_ms)

      true ->
        deliver(job, text, opts)
    end
  end

  @spec silent?(String.t() | nil, String.t() | nil) :: boolean()
  def silent?(text, marker) when is_binary(text) do
    String.trim(text) == (marker || "[SILENT]")
  end

  def silent?(_text, _marker), do: false

  defp deliver_with_timeout(job, text, opts, timeout_ms) do
    parent = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {result_ref, deliver(job, text, opts)})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        {:error, {:delivery_crashed, reason}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        flush_delivery_messages(monitor_ref, result_ref)
        {:error, :delivery_timeout}
    end
  end

  defp flush_delivery_messages(monitor_ref, result_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
        flush_delivery_messages(monitor_ref, result_ref)

      {^result_ref, _result} ->
        flush_delivery_messages(monitor_ref, result_ref)
    after
      0 ->
        :ok
    end
  end

  defp bounded_timeout?(timeout_ms), do: is_integer(timeout_ms) and timeout_ms >= 0

  defp immediate_delivery?(job, text) do
    delivery_mode(job) in ["none", "local"] or silent?(text, Map.get(job, :silent_marker))
  end

  defp deliver_to_channel(job, text, opts) do
    with {:ok, target} <- delivery_target(job),
         {:ok, adapter} <- delivery_adapter(target.platform, opts) do
      send_opts = target.opts ++ delivery_opts(opts)
      max_attempts = Keyword.get(opts, :delivery_max_attempts, @default_delivery_attempts)
      backoff_ms = Keyword.get(opts, :delivery_backoff_ms, @default_delivery_backoff_ms)

      # An unattended scheduled run already did its work, so a momentary HTTP
      # pool-checkout timeout (common right after wake-from-sleep) must not lose
      # its delivery. Retry the send with bounded backoff — but only on the
      # transient connection-unavailable error, which means the request never
      # obtained a connection (so a retry cannot duplicate a sent message).
      # Every other error fails fast.
      Enum.reduce_while(1..max_attempts, {:error, :not_attempted}, fn attempt, _acc ->
        adapter.send_message(target.destination, text, send_opts)
        |> decide_delivery_attempt(attempt, max_attempts, backoff_ms)
      end)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decide_delivery_attempt(:ok, _attempt, _max_attempts, _backoff_ms) do
    {:halt, {:ok, "sent"}}
  end

  defp decide_delivery_attempt({:error, reason}, attempt, max_attempts, backoff_ms)
       when attempt < max_attempts do
    if HttpClient.connection_unavailable?(reason) do
      Process.sleep(backoff_ms * attempt)
      {:cont, {:error, reason}}
    else
      {:halt, {:error, reason}}
    end
  end

  defp decide_delivery_attempt({:error, reason}, _attempt, _max_attempts, _backoff_ms) do
    {:halt, {:error, reason}}
  end

  defp decide_delivery_attempt(other, _attempt, _max_attempts, _backoff_ms) do
    {:halt, {:error, {:unexpected_delivery_result, other}}}
  end

  defp delivery_target(%{delivery_target: target}) when is_map(target) and map_size(target) > 0 do
    normalize_target(target)
  end

  defp delivery_target(%{delivery_mode: "origin", created_by_session_id: session_id})
       when is_binary(session_id) do
    origin_target(session_id)
  end

  defp delivery_target(_job), do: {:error, :missing_delivery_target}

  defp normalize_target(target) do
    with {:ok, platform} <- target_string(target, :platform, :channel),
         {:ok, destination} <-
           target_string(target, :chat_id, :reply_target, :target, :recipient, :channel_id) do
      {:ok, %{platform: platform, destination: destination, opts: target_opts(target)}}
    end
  end

  defp origin_target(session_id) do
    case String.split(session_id, ":", parts: 3) do
      [platform, destination, "root"] ->
        {:ok, %{platform: platform, destination: destination, opts: []}}

      [platform, destination, thread_scope] ->
        {:ok,
         %{
           platform: platform,
           destination: destination,
           opts: [thread_ts: thread_scope, message_thread_id: thread_scope]
         }}

      _parts ->
        {:error, {:invalid_origin_session_id, session_id}}
    end
  end

  defp delivery_adapter(platform, opts) do
    case Keyword.get(opts, :adapter) do
      adapter when is_atom(adapter) and not is_nil(adapter) ->
        ensure_adapter(adapter)

      _nil ->
        configured_adapter(platform, opts)
    end
  end

  defp configured_adapter(platform, opts) do
    channels = Keyword.get(opts, :channels, default_channels())

    channels
    |> fetch_channel(platform)
    |> case do
      nil -> {:error, {:unsupported_delivery_platform, platform}}
      adapter -> ensure_adapter(adapter)
    end
  end

  defp fetch_channel(channels, platform) when is_map(channels) do
    Map.get(channels, platform) || Map.get(channels, platform_atom(platform))
  end

  defp fetch_channel(channels, platform) when is_list(channels) do
    Keyword.get(channels, platform_atom(platform)) || Keyword.get(channels, platform)
  end

  defp fetch_channel(_channels, _platform), do: nil

  defp platform_atom("telegram"), do: :telegram
  defp platform_atom("slack"), do: :slack
  defp platform_atom("discord"), do: :discord
  defp platform_atom("signal"), do: :signal
  defp platform_atom("whatsapp"), do: :whatsapp
  defp platform_atom("cli"), do: :cli
  defp platform_atom(_platform), do: nil

  defp ensure_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :send_message, 3) do
      {:ok, adapter}
    else
      {:error, {:invalid_delivery_adapter, adapter}}
    end
  end

  defp ensure_adapter(adapter), do: {:error, {:invalid_delivery_adapter, adapter}}

  defp target_string(target, key, fallback_key) do
    target_string(target, [key, fallback_key])
  end

  defp target_string(target, key1, key2, key3, key4, key5) do
    target_string(target, [key1, key2, key3, key4, key5])
  end

  defp target_string(target, keys) do
    keys
    |> Enum.find_value(&target_value(target, &1))
    |> case do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_delivery_target_field, keys}}
    end
  end

  defp target_value(target, key) when is_atom(key) do
    Map.get(target, key) || Map.get(target, Atom.to_string(key))
  end

  defp target_opts(target) do
    []
    |> put_target_opt(:thread_ts, target_value(target, :thread_ts))
    |> put_target_opt(:message_thread_id, target_value(target, :message_thread_id))
    |> put_target_opt(:reply_to, target_value(target, :reply_to))
    |> put_target_opt(:req_options, target_value(target, :req_options))
  end

  defp put_target_opt(opts, _key, nil), do: opts
  defp put_target_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp delivery_opts(opts), do: Keyword.get(opts, :delivery_opts, [])

  defp default_channels do
    :fermix_core
    |> Application.get_env(:jobs, [])
    |> Keyword.get(:delivery_channels, %{})
  end

  defp delivery_mode(job), do: Map.get(job, :delivery_mode, "none")
end
