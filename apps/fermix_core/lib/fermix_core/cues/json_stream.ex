defmodule FermixCore.Cues.JsonStream do
  @moduledoc """
  The reader of a stream source with no preset: any WebSocket service that
  sends JSON (M60 WebSocket source §3). Pure: no socket, no clock, no store.
  The stream worker (`Cues.Source.Stream`) reads the secrets, connects, and
  hands each frame here.

  **Settings** (`check_config/1`, which `Cues.Config` runs on the section):
  `key_header` and `secret_header` are HTTP header names, different from each
  other and from the headers the upgrade sets itself (`Host`, `Connection`,
  `Upgrade`, `Sec-WebSocket-*`). `auth_message` and `subscribe_message` are at
  most 4 KiB of JSON, an object or a list; `auth_message` may carry `{{key}}`
  and `{{secret}}` inside its JSON strings and no other `{{`, and
  `subscribe_message` carries none. The check fills each placeholder with a
  stand-in holding a quote, escaped as it would be at connect, so a
  placeholder outside a JSON string is refused when the section is saved, not
  when the stream connects. The paths are `Cues.JsonPath`'s, and
  `item_types` or `error_types` needs `type_path`.

  **Signing in.** `secret_fields/1` names the secrets a source's sign-in uses:
  `key` when `key_header` or `{{key}}` appears, `secret` likewise.
  `headers/2` sends each stored value as its header's whole value;
  `messages/2` gives the sign-in message with its placeholders filled
  (JSON-escaped), then the message after connecting. The worker builds both
  from one read of the secrets when it dials, hands them to the transport
  (which sends the messages as soon as the upgrade completes), and keeps
  neither.

  **Reading** (`read/2`). A frame over 1 MiB is `{:error, :frame_too_large}`.
  A binary frame and a text frame that is not JSON are one reject each. The
  value at `items_path` (default `"."`) is the frame's messages: a list gives
  its entries (the first 100; the rest is counted in `over_limit`), an object
  gives itself, and nothing there skips the frame. A message whose type (at
  `type_path`) is in `error_types` is the service's error, carried as its
  canonical JSON with control characters removed, at most 512 bytes, for the
  log and the trace only. With `item_types` set, a message of another type is
  skipped. Every other message is an item, read by the paths exactly as a JSON
  API feed reads one (`Cues.JsonPath.fields/3`), with type `"stream.item"`
  when it has none; one with no id is a reject.
  """

  alias FermixCore.Cues.JsonPath
  alias FermixCore.Plugins.CanonicalJson

  @max_frame_bytes 1024 * 1024
  @max_entries 100
  @max_message_bytes 4 * 1024
  @max_words_bytes 512
  @item_type "stream.item"

  @path_fields [:items_path, :id_path, :revision_path, :type_path, :subject_path, :time_path]

  @header_name ~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]{1,64}\z/
  @reserved_headers ~w(host connection upgrade)
  @placeholder ~r/\{\{(key|secret)\}\}/
  # Holds a quote, so it is valid JSON only where it lands inside a string.
  @stand_in ~s(stand"in)
  @unsendable ~r/[\x00-\x08\x0A-\x1F\x7F]/
  @control ~r/[\x00-\x1F\x7F]/

  @binary_frame "The stream sent a binary frame, and this source reads JSON text."
  @not_json "The stream sent a frame that is not JSON."
  @no_id "A message has no id at the source's id path."

  @type secrets :: %{optional(:key | :secret) => String.t()}

  @type entry ::
          {:item, map()}
          | {:reject, String.t()}
          | {:service_error, String.t()}
          | :skip

  @type read :: %{entries: [entry()], over_limit: non_neg_integer()}

  @doc "The largest frame this reader takes: 1 MiB."
  @spec max_frame_bytes() :: pos_integer()
  def max_frame_bytes, do: @max_frame_bytes

  @doc """
  The secrets `source`'s sign-in uses, key first: `:key` when it has a
  `key_header` or its `auth_message` holds `{{key}}`, `:secret` likewise.
  """
  @spec secret_fields(map()) :: [:key | :secret]
  def secret_fields(source) when is_map(source) do
    message = Map.get(source, :auth_message) || ""

    for {field, header} <- [key: :key_header, secret: :secret_header],
        Map.get(source, header) != nil or String.contains?(message, "{{#{field}}}"),
        do: field
  end

  @doc """
  The upgrade's sign-in headers: each stored value as its header's whole
  value. `secrets` holds every field `secret_fields/1` names. A value with a
  line break or another control character cannot be a header value and is
  refused, naming the field and never the value.
  """
  @spec headers(map(), secrets()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def headers(source, secrets) when is_map(source) and is_map(secrets) do
    [key: :key_header, secret: :secret_header]
    |> Enum.filter(fn {_field, header} -> Map.get(source, header) != nil end)
    |> Enum.reduce_while({:ok, []}, fn {field, header}, {:ok, acc} ->
      value = Map.fetch!(secrets, field)

      if Regex.match?(@unsendable, value),
        do: {:halt, {:error, {:unsendable_secret, field}}},
        else: {:cont, {:ok, acc ++ [{Map.fetch!(source, header), value}]}}
    end)
  end

  @doc """
  The messages sent as soon as the connection opens, in order: the sign-in
  message with `{{key}}` and `{{secret}}` filled from `secrets`, JSON-escaped,
  then the message after connecting. A value that cannot be JSON text (not
  UTF-8) is refused, naming the field.
  """
  @spec messages(map(), secrets()) :: {:ok, [String.t()]} | {:error, term()}
  def messages(source, secrets) when is_map(source) and is_map(secrets) do
    with {:ok, escaped} <- escape_all(secrets),
         {:ok, sign_in} <- fill(Map.get(source, :auth_message), escaped) do
      {:ok, Enum.reject([sign_in, Map.get(source, :subscribe_message)], &is_nil/1)}
    end
  end

  defp escape_all(secrets) do
    Enum.reduce_while(secrets, {:ok, %{}}, fn {field, value}, {:ok, acc} ->
      case escape(value) do
        {:ok, text} -> {:cont, {:ok, Map.put(acc, field, text)}}
        :error -> {:halt, {:error, {:unsendable_secret, field}}}
      end
    end)
  end

  defp fill(nil, _escaped), do: {:ok, nil}

  defp fill(template, escaped) do
    {:ok,
     Regex.replace(@placeholder, template, fn _whole, name ->
       Map.fetch!(escaped, placeholder_field(name))
     end)}
  end

  defp placeholder_field("key"), do: :key
  defp placeholder_field("secret"), do: :secret

  # A value's text inside a JSON string: its JSON encoding less the quotes.
  defp escape(value) when is_binary(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, binary_part(json, 1, byte_size(json) - 2)}
      {:error, _reason} -> :error
    end
  end

  # --- settings ----------------------------------------------------------------

  @doc """
  Checks a stream section with no preset (a map with atom keys, normalized
  values): `:ok`, or `{:error, field, words}`, `words` following the field's
  name in the owner's sentence (`cues.sources.<ref>.<field> <words>`).
  """
  @spec check_config(map()) :: :ok | {:error, atom(), String.t()}
  def check_config(filled) when is_map(filled) do
    with :ok <- check_host(filled),
         :ok <- check_headers(filled),
         :ok <- check_message(filled, :auth_message),
         :ok <- check_message(filled, :subscribe_message),
         :ok <- check_paths(filled) do
      check_types(filled)
    end
  end

  defp check_host(%{url: url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> :ok
      %URI{} -> {:error, :url, "must name a host"}
    end
  end

  defp check_host(_filled), do: :ok

  defp check_headers(filled) do
    key = Map.get(filled, :key_header)
    secret = Map.get(filled, :secret_header)

    with :ok <- check_header(:key_header, key),
         :ok <- check_header(:secret_header, secret) do
      if key != nil and secret != nil and String.downcase(key) == String.downcase(secret),
        do: {:error, :secret_header, "must differ from key_header"},
        else: :ok
    end
  end

  defp check_header(_field, nil), do: :ok

  defp check_header(field, name) do
    lower = String.downcase(name)

    cond do
      not Regex.match?(@header_name, name) ->
        {:error, field, "is not a header name"}

      lower in @reserved_headers ->
        {:error, field, "is a header the connection sets itself"}

      String.starts_with?(lower, "sec-websocket-") ->
        {:error, field, "is a header the connection sets itself"}

      true ->
        :ok
    end
  end

  defp check_message(filled, field) do
    case Map.get(filled, field) do
      nil -> :ok
      text when byte_size(text) > @max_message_bytes -> {:error, field, "is longer than 4 KiB"}
      text -> check_json(field, text)
    end
  end

  defp check_json(:auth_message, text) do
    if Regex.replace(@placeholder, text, "") =~ "{{" do
      {:error, :auth_message, "takes no placeholder but {{key}} and {{secret}}"}
    else
      {:ok, filled} = fill(text, %{key: stand_in(), secret: stand_in()})
      json_container(:auth_message, filled, ", with each placeholder inside a JSON string")
    end
  end

  defp check_json(:subscribe_message, text) do
    if text =~ "{{",
      do: {:error, :subscribe_message, "takes no placeholder"},
      else: json_container(:subscribe_message, text, "")
  end

  defp stand_in do
    {:ok, escaped} = escape(@stand_in)
    escaped
  end

  defp json_container(field, text, where) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) or is_list(value) -> :ok
      _other -> {:error, field, "must be a JSON object or list on one line#{where}"}
    end
  end

  defp check_paths(filled) do
    case Enum.find(@path_fields, &(Map.has_key?(filled, &1) and not JsonPath.valid?(filled[&1]))) do
      nil -> :ok
      field -> {:error, field, "is not a dot path of keys"}
    end
  end

  defp check_types(filled) do
    typed = Enum.find([:item_types, :error_types], &(Map.get(filled, &1, []) != []))

    if typed && not Map.has_key?(filled, :type_path),
      do: {:error, typed, "needs type_path, where each message keeps its type"},
      else: :ok
  end

  # --- reading -----------------------------------------------------------------

  @doc """
  Reads one frame of `source` (its paths, `item_types` and `error_types`).
  """
  @spec read({:text | :binary, binary()}, map()) :: {:ok, read()} | {:error, :frame_too_large}
  def read({kind, payload}, source)
      when kind in [:text, :binary] and is_binary(payload) and is_map(source) do
    cond do
      byte_size(payload) > @max_frame_bytes -> {:error, :frame_too_large}
      kind == :binary -> {:ok, %{entries: [{:reject, @binary_frame}], over_limit: 0}}
      true -> {:ok, decoded(Jason.decode(payload), source)}
    end
  end

  defp decoded({:error, %Jason.DecodeError{}}, _source),
    do: %{entries: [{:reject, @not_json}], over_limit: 0}

  defp decoded({:ok, document}, source) do
    case JsonPath.lookup(document, Map.get(source, :items_path) || ".") do
      {:ok, list} when is_list(list) ->
        {kept, rest} = Enum.split(list, @max_entries)
        %{entries: Enum.map(kept, &entry(&1, source)), over_limit: length(rest)}

      {:ok, %{} = message} ->
        %{entries: [entry(message, source)], over_limit: 0}

      _nothing ->
        %{entries: [:skip], over_limit: 0}
    end
  end

  defp entry(message, source) do
    type = JsonPath.scalar(message, Map.get(source, :type_path))
    item_types = Map.get(source, :item_types) || []

    cond do
      type != nil and type in (Map.get(source, :error_types) || []) ->
        {:service_error, words(message)}

      item_types != [] and type not in item_types ->
        :skip

      true ->
        item(JsonPath.fields(message, source, @item_type))
    end
  end

  defp item(%{item_id: nil}), do: {:reject, @no_id}
  defp item(fields), do: {:item, fields}

  # The service's words, for the log and the trace: its canonical JSON with
  # control characters removed, at most 512 bytes, cut on a character.
  defp words(message) do
    text =
      case CanonicalJson.encode(message) do
        {:ok, json} -> json
        {:error, reason} -> "(the message is not printable as JSON: #{inspect(reason)})"
      end

    text |> String.replace(@control, "") |> bounded()
  end

  defp bounded(text) when byte_size(text) <= @max_words_bytes, do: text

  defp bounded(text) do
    [valid | _rest] = text |> binary_part(0, @max_words_bytes) |> String.chunk(:valid)
    valid
  end
end
