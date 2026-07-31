defmodule FermixCore.Jobs.Delivery do
  @moduledoc """
  Scheduler-owned delivery for completed scheduled job runs.

  The core app stays decoupled from channel implementations by resolving channel
  modules from configuration or test injection and calling their `send_message/3`
  contract dynamically.
  """

  alias FermixCore.Delivery.ChannelSend

  @type delivery_result :: {:ok, String.t()} | {:error, term()}

  @default_timeout_ms 60_000

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
    ChannelSend.with_timeout(timeout_ms, fn -> deliver(job, text, opts) end)
  end

  defp bounded_timeout?(timeout_ms), do: is_integer(timeout_ms) and timeout_ms >= 0

  defp immediate_delivery?(job, text) do
    delivery_mode(job) in ["none", "local"] or silent?(text, Map.get(job, :silent_marker))
  end

  defp deliver_to_channel(job, text, opts) do
    with {:ok, target} <- delivery_target(job) do
      send_opts = target.opts ++ delivery_opts(opts)

      case ChannelSend.send(target.platform, target.destination, text, send_opts, opts) do
        :ok -> {:ok, "sent"}
        {:error, reason} -> {:error, reason}
      end
    end
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

  defp delivery_mode(job), do: Map.get(job, :delivery_mode, "none")
end
