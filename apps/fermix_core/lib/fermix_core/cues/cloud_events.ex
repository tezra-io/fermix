defmodule FermixCore.Cues.CloudEvents do
  @moduledoc """
  CloudEvents 1.0 in JSON, structured (`application/cloudevents+json`) and
  batch (`application/cloudevents-batch+json`) mode, the format local push
  speaks (M60 §6.6).

  The body is decoded with `Plugins.CanonicalJson.decode/1`, which refuses a
  repeated key anywhere in it. A body that is not JSON, or not the shape its
  mode promises, is refused as a request; a bad event inside a valid body is
  reported on its own line, so one bad event never refuses its batch.

  Each good event becomes the field map `Cues.Item.new/2` takes. Its item id is
  the (`source`, `id`) pair, the uniqueness CloudEvents defines, hashed into
  one string so two producers sharing one Fermix source cannot collide. The
  event's `source` is the producer's and never chooses the Fermix source.
  """

  alias FermixCore.Plugins.CanonicalJson

  @structured_type "application/cloudevents+json"
  @batch_type "application/cloudevents-batch+json"
  @max_batch_events 1_000
  @item_id_prefix "ce_"

  @type mode :: :structured | :batch
  @type fields :: %{
          item_id: String.t(),
          revision: String.t(),
          type: String.t(),
          subject: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          datacontenttype: String.t() | nil,
          data: term(),
          title: nil
        }
  @type entry :: %{id: String.t() | nil, result: {:ok, fields()} | {:error, String.t()}}
  @type refusal ::
          :invalid_json | :duplicate_object_key | :not_an_event | :not_a_batch | :too_many_events

  @doc "The most events one batch may carry."
  @spec max_batch_events() :: pos_integer()
  def max_batch_events, do: @max_batch_events

  @doc """
  The mode a `Content-Type` header names, parameters and case aside; `:error`
  for any other media type or none.
  """
  @spec media_mode(String.t() | nil) :: {:ok, mode()} | :error
  def media_mode(content_type) when is_binary(content_type) do
    media_type =
      content_type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    case media_type do
      @structured_type -> {:ok, :structured}
      @batch_type -> {:ok, :batch}
      _other -> :error
    end
  end

  def media_mode(_content_type), do: :error

  @doc """
  Decodes a body in `mode` into one entry per event, in order: the event's
  `id` when it has a string one, and its fields or the sentence saying why it
  is invalid.
  """
  @spec decode(mode(), binary()) :: {:ok, [entry()]} | {:error, refusal()}
  def decode(mode, body) when mode in [:structured, :batch] and is_binary(body) do
    with {:ok, decoded} <- CanonicalJson.decode(body),
         {:ok, events} <- events(mode, decoded) do
      {:ok, Enum.map(events, &entry/1)}
    end
  end

  defp events(:structured, %Jason.OrderedObject{} = event), do: {:ok, [event]}
  defp events(:structured, _other), do: {:error, :not_an_event}

  defp events(:batch, events) when is_list(events) and length(events) > @max_batch_events,
    do: {:error, :too_many_events}

  defp events(:batch, events) when is_list(events), do: {:ok, events}
  defp events(:batch, _other), do: {:error, :not_a_batch}

  defp entry(%Jason.OrderedObject{} = object) do
    event = plain(object)
    %{id: event_id(event), result: fields(event)}
  end

  defp entry(_not_an_object), do: %{id: nil, result: {:error, "an event must be a JSON object"}}

  defp event_id(%{"id" => id}) when is_binary(id) and id != "", do: id
  defp event_id(_event), do: nil

  defp fields(event) do
    with :ok <- check_specversion(event),
         {:ok, id} <- required_string(event, "id"),
         {:ok, source} <- required_string(event, "source"),
         {:ok, type} <- required_string(event, "type"),
         {:ok, subject} <- optional_string(event, "subject"),
         {:ok, content_type} <- optional_string(event, "datacontenttype"),
         {:ok, revision} <- revision(event),
         {:ok, occurred_at} <- time(event),
         :ok <- refuse_binary_data(event) do
      {:ok,
       %{
         item_id: item_id(source, id),
         revision: revision,
         type: type,
         subject: subject,
         occurred_at: occurred_at,
         datacontenttype: content_type,
         data: Map.get(event, "data"),
         title: nil
       }}
    end
  end

  defp check_specversion(%{"specversion" => "1.0"}), do: :ok
  defp check_specversion(_event), do: {:error, ~s(specversion must be "1.0")}

  defp required_string(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, "#{key} is required and must be a non-empty string"}
    end
  end

  defp optional_string(event, key) do
    case Map.get(event, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, "#{key} must be a string"}
    end
  end

  defp revision(event) do
    case Map.get(event, "revision") do
      nil -> {:ok, "1"}
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_integer(value) and value >= 0 -> {:ok, Integer.to_string(value)}
      _other -> {:error, "revision must be a non-empty string or a non-negative integer"}
    end
  end

  defp time(event) do
    case Map.get(event, "time") do
      nil -> {:ok, nil}
      value when is_binary(value) -> parse_time(value)
      _other -> {:error, "time must be an RFC 3339 timestamp"}
    end
  end

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, "time #{inspect(value)} is not an RFC 3339 timestamp"}
    end
  end

  defp refuse_binary_data(%{"data_base64" => _data}),
    do: {:error, "data_base64 is not supported; send data as JSON or text"}

  defp refuse_binary_data(_event), do: :ok

  # The pair is canonical JSON, so no choice of strings can make two different
  # pairs hash alike.
  defp item_id(source, id) do
    {:ok, digest} = CanonicalJson.digest([source, id])
    @item_id_prefix <> digest
  end

  # Keys are unique once `CanonicalJson.decode/1` accepted the body.
  defp plain(%Jason.OrderedObject{values: pairs}),
    do: Map.new(pairs, fn {key, value} -> {key, plain(value)} end)

  defp plain(values) when is_list(values), do: Enum.map(values, &plain/1)
  defp plain(value), do: value
end
