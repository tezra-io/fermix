defmodule FermixCore.Cues.Item do
  @moduledoc """
  One normalised input item, the same for every source kind (design §6.8).
  Pure: `new/2` validates, hashes and summarises; it does no I/O.

  - **Identity** is `(source_ref, item_id, revision)`; `revision` defaults to `"1"`.
  - **Content hash** is `CanonicalJson.digest/1` over type, subject, content
    type, data and revision, leaving out the time. Data that cannot be
    canonicalised (an integer beyond ±(2^53 − 1)) is invalid.
  - **Size:** the canonical encoding of `data` is at most 64 KiB.
  - **Staleness:** an item whose time is older than the 7-day receipt horizon is
    `{:error, :stale}`. An item with no time is never stale.
  - **Snapshot:** JSON of type, subject and `text`, the item's own words where
    it has them, by one rule: the title; else the data when it is text; else
    the data's `"text"` field when that is a string with something in it (an X
    post, a stream that keeps one); else the canonical JSON of the data. Cut at
    280 characters, which holds a whole standard X post: a marked example's
    snapshot reaches every filter and screen call of its watcher, 20 of them at
    most, so the bound sizes that prompt.
  - `self_caused?` marks Fermix's own action coming back (stored, never routed);
    `receipt_only?` stores a receipt with no delivery (a feed's undated items on
    the first poll after the source is added); `body_hash` is a webhook's raw
    body hash, a duplicate within the horizon whatever its delivery id.
  """

  alias FermixCore.Plugins.CanonicalJson

  @max_data_bytes 65_536
  @horizon_days 7
  @excerpt_chars 280
  @max_text_bytes 1_024
  @max_title_bytes 4_096

  @input_fields [
    :item_id,
    :revision,
    :type,
    :subject,
    :occurred_at,
    :datacontenttype,
    :data,
    :title,
    :self_caused?,
    :body_hash,
    :receipt_only?
  ]
  @text_fields [:type, :subject, :datacontenttype, :body_hash]

  @enforce_keys [:item_id, :content_hash, :payload, :payload_bytes, :snapshot]
  defstruct item_id: nil,
            revision: "1",
            type: nil,
            subject: nil,
            occurred_at: nil,
            datacontenttype: nil,
            data: nil,
            title: nil,
            self_caused?: false,
            body_hash: nil,
            receipt_only?: false,
            content_hash: nil,
            payload: nil,
            payload_bytes: 0,
            snapshot: nil

  @type t :: %__MODULE__{
          item_id: String.t(),
          revision: String.t(),
          type: String.t() | nil,
          subject: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          datacontenttype: String.t() | nil,
          data: term(),
          title: String.t() | nil,
          self_caused?: boolean(),
          body_hash: String.t() | nil,
          receipt_only?: boolean(),
          content_hash: String.t(),
          payload: String.t(),
          payload_bytes: non_neg_integer(),
          snapshot: String.t()
        }

  @doc "The receipt horizon in days: older items are stale (design §7.4)."
  @spec horizon_days() :: pos_integer()
  def horizon_days, do: @horizon_days

  @doc """
  Builds an item from `fields` at `now`. An unknown field raises: fields come
  from code, never from the payload.
  """
  @spec new(map(), DateTime.t()) ::
          {:ok, t()} | {:error, {:invalid, String.t()}} | {:error, :stale}
  def new(fields, %DateTime{} = now) when is_map(fields) do
    unknown_fields!(fields)

    with {:ok, base} <- validate(fields),
         {:ok, payload} <- encode_data(base.data),
         {:ok, hash} <- content_hash(base),
         :ok <- fresh(base.occurred_at, now) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(base, %{
           payload: payload,
           payload_bytes: byte_size(payload),
           content_hash: hash,
           snapshot: snapshot(base, payload)
         })
       )}
    end
  end

  defp unknown_fields!(fields) do
    case Map.keys(fields) -- @input_fields do
      [] -> :ok
      unknown -> raise ArgumentError, "Cues.Item.new/2 got unknown fields #{inspect(unknown)}"
    end
  end

  defp validate(fields) do
    with {:ok, item_id} <- required_text(fields, :item_id, "id"),
         {:ok, revision} <- revision(Map.get(fields, :revision, "1")),
         {:ok, texts} <- optional_texts(fields),
         {:ok, title} <- optional_text(fields, :title, @max_title_bytes),
         {:ok, occurred_at} <- occurred_at(Map.get(fields, :occurred_at)),
         {:ok, flags} <- flags(fields) do
      {:ok,
       texts
       |> Map.merge(flags)
       |> Map.merge(%{
         item_id: item_id,
         revision: revision,
         title: title,
         occurred_at: occurred_at,
         data: Map.get(fields, :data)
       })}
    end
  end

  defp required_text(fields, key, name) do
    case Map.get(fields, key) do
      value when is_binary(value) and value != "" -> bounded(value, name, @max_text_bytes)
      _missing -> invalid("The item has no #{name}.")
    end
  end

  defp revision(value) when is_binary(value) and value != "",
    do: bounded(value, "revision", @max_text_bytes)

  defp revision(_value), do: invalid("The item's revision is not text.")

  defp optional_texts(fields) do
    Enum.reduce_while(@text_fields, {:ok, %{}}, fn key, {:ok, acc} ->
      case optional_text(fields, key, @max_text_bytes) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp optional_text(fields, key, max_bytes) do
    case Map.get(fields, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> bounded(value, Atom.to_string(key), max_bytes)
      _other -> invalid("The item's #{key} is not text.")
    end
  end

  defp bounded(value, name, max_bytes) do
    cond do
      not String.valid?(value) ->
        invalid("The item's #{name} is not UTF-8 text.")

      byte_size(value) > max_bytes ->
        invalid("The item's #{name} is longer than #{max_bytes} bytes.")

      true ->
        {:ok, value}
    end
  end

  defp occurred_at(nil), do: {:ok, nil}
  defp occurred_at(%DateTime{} = at), do: {:ok, DateTime.shift_zone!(at, "Etc/UTC")}
  defp occurred_at(_other), do: invalid("The item's time is not a timestamp.")

  defp flags(fields) do
    self_caused? = Map.get(fields, :self_caused?, false)
    receipt_only? = Map.get(fields, :receipt_only?, false)

    if is_boolean(self_caused?) and is_boolean(receipt_only?) do
      {:ok, %{self_caused?: self_caused?, receipt_only?: receipt_only?}}
    else
      invalid("The item's flags are not true or false.")
    end
  end

  defp encode_data(data) do
    case CanonicalJson.encode(data) do
      {:ok, payload} -> check_payload(payload)
      {:error, {:integer_out_of_range, _value}} -> invalid(huge_number())
      {:error, _reason} -> invalid("The item's data is not JSON.")
    end
  end

  defp check_payload(payload) do
    cond do
      byte_size(payload) > @max_data_bytes -> invalid("The item's data is larger than 64 KiB.")
      not String.valid?(payload) -> invalid("The item's data is not UTF-8 text.")
      true -> {:ok, payload}
    end
  end

  defp content_hash(base) do
    term = %{
      "type" => base.type,
      "subject" => base.subject,
      "datacontenttype" => base.datacontenttype,
      "data" => base.data,
      "revision" => base.revision
    }

    case CanonicalJson.digest(term) do
      {:ok, hash} -> {:ok, hash}
      {:error, {:integer_out_of_range, _value}} -> invalid(huge_number())
      {:error, _reason} -> invalid("The item's data is not JSON.")
    end
  end

  defp huge_number, do: "The item's data holds a number outside the range JSON can carry exactly."

  defp fresh(nil, _now), do: :ok

  defp fresh(occurred_at, now) do
    horizon = DateTime.add(now, -@horizon_days, :day)
    if DateTime.compare(occurred_at, horizon) == :lt, do: {:error, :stale}, else: :ok
  end

  defp snapshot(base, payload) do
    Jason.encode!(%{
      "type" => base.type,
      "subject" => base.subject,
      "text" => base.title || excerpt(base.data, payload)
    })
  end

  defp excerpt(nil, _payload), do: nil
  defp excerpt(text, _payload) when is_binary(text), do: cut(text)
  defp excerpt(data, payload), do: cut(words(data) || payload)

  # The item's own words in data that is not text: its `"text"` field, when that
  # is a string with something in it.
  defp words(%{"text" => text}) when is_binary(text),
    do: if(String.trim(text) == "", do: nil, else: text)

  defp words(_data), do: nil

  defp cut(text), do: String.slice(text, 0, @excerpt_chars)

  defp invalid(message), do: {:error, {:invalid, message}}
end
