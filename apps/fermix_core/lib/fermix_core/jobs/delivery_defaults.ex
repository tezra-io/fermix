defmodule FermixCore.Jobs.DeliveryDefaults do
  @moduledoc """
  Creation-time delivery defaults for scheduled jobs.

  Defaults are resolved into the scheduled job row when the job is created so
  later config edits do not silently retarget existing jobs.
  """

  @valid_modes ~w(none origin channel local)
  @destination_keys ~w(chat_id channel_id recipient target reply_target)

  @spec resolve(map(), map(), keyword()) ::
          {:ok, {String.t(), map() | nil}} | {:error, term()}
  def resolve(args, context, opts \\ []) when is_map(args) and is_map(context) do
    mode = optional_string(args, "delivery_mode")
    target = optional_map(args, "delivery_target")
    jobs_config = jobs_config(opts)

    {raw_mode, raw_target} =
      cond do
        is_binary(mode) ->
          {mode, target_for_mode(mode, target, context, jobs_config)}

        is_map(target) ->
          {"channel", normalize_target(target)}

        true ->
          configured_default(context, jobs_config)
      end

    validate(raw_mode, raw_target)
  end

  @doc """
  Resolve delivery for an in-place job update.

  Unlike `resolve/3`, an absent `delivery_mode`/`delivery_target` yields
  `:no_change` rather than the configured default — editing an unrelated field
  must never silently retarget the job (rule #12: no fallback). An explicitly
  supplied delivery is validated exactly as on creation, including rejecting an
  unknown mode.
  """
  @spec resolve_update(map(), map(), keyword()) ::
          :no_change | {:ok, {String.t(), map() | nil}} | {:error, term()}
  def resolve_update(args, context, opts \\ []) when is_map(args) and is_map(context) do
    raw_mode = Map.get(args, "delivery_mode")
    raw_target = Map.get(args, "delivery_target")

    cond do
      is_nil(raw_mode) and is_nil(raw_target) ->
        :no_change

      is_binary(raw_mode) ->
        mode = String.trim(raw_mode)
        target = optional_map(args, "delivery_target")
        validate(mode, target_for_mode(mode, target, context, jobs_config(opts)))

      is_map(raw_target) ->
        validate("channel", normalize_target(raw_target))

      true ->
        {:error, {:invalid_delivery_mode, inspect(raw_mode)}}
    end
  end

  defp validate(mode, _target) when mode in ["none", "local"], do: {:ok, {mode, nil}}

  defp validate("channel", target) when is_map(target) do
    case validate_channel_target(target) do
      :ok -> {:ok, {"channel", target}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate("channel", _target) do
    {:error,
     {:invalid_delivery_target,
      ~s(delivery_mode "channel" requires delivery_target with "platform" and one of: ) <>
        Enum.join(@destination_keys, ", ")}}
  end

  defp validate("origin", target) when is_map(target) do
    case validate_channel_target(target) do
      :ok -> {:ok, {"origin", target}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate("origin", _target) do
    {:error,
     {:invalid_delivery_target,
      ~s(delivery_mode "origin" requires a conversation context — schedule from a channel or pass an explicit delivery_target)}}
  end

  defp validate(mode, _target), do: {:error, {:invalid_delivery_mode, mode}}

  defp validate_channel_target(target) do
    cond do
      not Map.has_key?(target, "platform") ->
        {:error, {:invalid_delivery_target, ~s(delivery_target is missing "platform")}}

      not Enum.any?(@destination_keys, &Map.has_key?(target, &1)) ->
        {:error,
         {:invalid_delivery_target,
          ~s(delivery_target is missing a destination — provide one of: ) <>
            Enum.join(@destination_keys, ", ")}}

      true ->
        :ok
    end
  end

  defp configured_default(context, jobs_config) do
    target = normalize_target(Keyword.get(jobs_config, :default_delivery_target))
    mode = normalize_mode(Keyword.get(jobs_config, :default_delivery_mode))

    case {mode, target} do
      {nil, t} when is_map(t) -> {"channel", t}
      {nil, _} -> {"none", nil}
      {"channel", t} -> {"channel", t}
      {"origin", _} -> {"origin", origin_target(context)}
      {m, _} when m in ["none", "local"] -> {m, nil}
    end
  end

  defp target_for_mode("origin", nil, context, _jobs_config), do: origin_target(context)

  defp target_for_mode("channel", nil, _context, jobs_config) do
    normalize_target(Keyword.get(jobs_config, :default_delivery_target))
  end

  defp target_for_mode(mode, target, _context, _jobs_config) when mode in ["channel", "origin"],
    do: normalize_target(target)

  defp target_for_mode(_mode, _target, _context, _jobs_config), do: nil

  defp jobs_config(opts) do
    Keyword.get_lazy(opts, :jobs_config, fn ->
      Application.get_env(:fermix_core, :jobs, [])
    end)
  end

  defp origin_target(%{conversation_key: {channel, chat_id, :root}}) do
    %{"platform" => target_part(channel), "chat_id" => target_part(chat_id)}
  end

  defp origin_target(%{conversation_key: {channel, chat_id, thread_scope}}) do
    thread = target_part(thread_scope)

    %{
      "platform" => target_part(channel),
      "chat_id" => target_part(chat_id),
      "thread_ts" => thread,
      "message_thread_id" => thread
    }
  end

  defp origin_target(_context), do: nil

  defp normalize_target(nil), do: nil

  defp normalize_target(target) when is_map(target) or is_list(target) do
    target
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case {target_key(key), target_part(value)} do
        {nil, _value} -> acc
        {_key, nil} -> acc
        {key, value} -> Map.put(acc, key, value)
      end
    end)
    |> empty_to_nil()
  end

  defp normalize_target(_target), do: nil

  defp target_key(key) when is_atom(key), do: target_key(Atom.to_string(key))

  defp target_key(key) when is_binary(key) do
    if key in ~w(platform channel chat_id reply_target target recipient channel_id thread_ts message_thread_id reply_to) do
      key
    end
  end

  defp target_key(_key), do: nil

  defp optional_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value in @valid_modes, do: value

      _value ->
        nil
    end
  end

  defp optional_map(args, key) do
    case Map.get(args, key) do
      value when is_map(value) -> normalize_target(value)
      _value -> nil
    end
  end

  defp normalize_mode(value) when is_atom(value), do: normalize_mode(Atom.to_string(value))

  defp normalize_mode(value) when is_binary(value) do
    value = String.trim(value)
    if value in @valid_modes, do: value
  end

  defp normalize_mode(_value), do: nil

  defp target_part(:root), do: "root"

  defp target_part(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp target_part(value) when is_integer(value), do: Integer.to_string(value)
  defp target_part(value) when is_atom(value), do: Atom.to_string(value)
  defp target_part(_value), do: nil

  defp empty_to_nil(map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map
end
