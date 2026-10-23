defmodule FermixCore.Cues.Jetstream do
  @moduledoc """
  Bluesky Jetstream for the `bluesky_jetstream` preset (M60 §6.3, §6.10): the
  subscribe URL, and one frame decoded into a cue item or a skip.

  Pure: no socket, no clock. The stream worker connects, reads text frames and
  keeps the cursor.

  Built against Jetstream v2, the generation its documentation recommends
  (github.com/bluesky-social/jetstream, `docs/README.md` §5.2 and the
  `network.bsky.jetstream.subscribeEvents` lexicon, read 2026-10-17):

    * endpoint `/xrpc/network.bsky.jetstream.subscribeEvents` on the public
      v2 hosts (`wss://jetstream.us-east.bsky.network`); no authentication;
    * filters `kinds`, `dids` (at most 10,000) and `collections` (at most 100,
      NSIDs or `prefix.*`), each repeated; the v1 names `wantedDids` and
      `wantedCollections` are refused there with a 400;
    * `cursor`: a value of 1e15 or more is a unix-microsecond time, translated
      to the first event witnessed at or after it; below that it is the
      instance's own sequence number. This module only ever sends a time, so
      the cursor stays portable across hosts (§6.3: last good time minus 5
      minutes); a time older than the lookback is clamped and announced by an
      `#info OutdatedCursor` frame;
    * every frame is `{"$type": "message", "payload": {...}}` or a terminal
      `{"$type": "error", "error": name}`. Event payloads carry `seq`, `did`
      and `time` (RFC 3339, microseconds); a commit adds `operation`,
      `collection`, `rkey`, and `record` and `cid` unless it is a delete.

  The subscription asks for commits only (`kinds=commit`) in the followed
  accounts. Decoding trusts neither filter: only a `create` by a followed DID
  becomes an item (C47); everything else is a skip that still carries its time.
  """

  @default_base_url "wss://jetstream.us-east.bsky.network"
  @default_collections ["app.bsky.feed.post"]
  @subscribe_path "/xrpc/network.bsky.jetstream.subscribeEvents"

  @max_frame_bytes 128 * 1024
  @max_dids 10_000
  @max_collections 100
  @min_time_cursor 1_000_000_000_000_000
  @max_title_chars 300
  @max_name_chars 64

  @commit "network.bsky.jetstream.subscribeEvents#commit"
  @info "network.bsky.jetstream.subscribeEvents#info"
  @skipped_kinds %{
    "network.bsky.jetstream.subscribeEvents#identity" => :identity,
    "network.bsky.jetstream.subscribeEvents#account" => :account,
    "network.bsky.jetstream.subscribeEvents#sync" => :sync
  }

  @did ~r/^did:[a-z]+:[A-Za-z0-9._:%-]{1,2000}$/
  @nsid ~r/^[A-Za-z][A-Za-z0-9-]{0,62}(\.[A-Za-z0-9-]{1,63})+$/
  @collection_pattern ~r/^[A-Za-z][A-Za-z0-9-]{0,62}(\.[A-Za-z0-9-]{1,63})*\.\*$/
  @rkey ~r/^[A-Za-z0-9._:~-]{1,512}$/
  @loopback_hosts ["127.0.0.1", "::1", "localhost"]

  @type fields :: %{
          item_id: String.t(),
          revision: String.t(),
          type: String.t(),
          subject: String.t(),
          occurred_at: DateTime.t(),
          datacontenttype: String.t(),
          data: map(),
          title: String.t() | nil
        }

  @type skip_reason ::
          :update
          | :delete
          | :unknown_operation
          | :not_followed
          | :identity
          | :account
          | :sync
          | :unknown_kind
          | {:info, String.t()}

  @type decoded ::
          {:item, fields(), integer()}
          | {:skip, skip_reason(), integer() | nil}
          | {:error,
             :frame_too_large | :invalid_json | :invalid_frame | {:stream_error, String.t()}}

  @doc "The public v2 host the preset uses."
  @spec default_base_url() :: String.t()
  def default_base_url, do: @default_base_url

  @doc "The collections a source follows when it names none: posts."
  @spec default_collections() :: [String.t()]
  def default_collections, do: @default_collections

  @doc """
  Checks a subscription with a sentence for the owner: at least one DID and at
  most 10,000, at least one collection and at most 100, each well formed.
  """
  @spec check_subscription([String.t()], [String.t()]) :: :ok | {:error, String.t()}
  def check_subscription(dids, collections) when is_list(dids) and is_list(collections) do
    cond do
      dids == [] ->
        {:error, "a Bluesky stream needs dids, the accounts to follow"}

      length(dids) > @max_dids ->
        {:error, "a Bluesky stream follows at most #{@max_dids} accounts"}

      collections == [] ->
        {:error, "a Bluesky stream needs at least one collection"}

      length(collections) > @max_collections ->
        {:error, "a Bluesky stream takes at most #{@max_collections} collections"}

      bad = Enum.find(dids, &(not did?(&1))) ->
        {:error, "#{inspect(bad)} is not a DID"}

      bad = Enum.find(collections, &(not collection?(&1))) ->
        {:error, "#{inspect(bad)} is not a collection"}

      true ->
        :ok
    end
  end

  @doc """
  The WebSocket URL for `dids` and `collections`, resuming at `cursor_us` (a
  unix-microsecond time) or at the live tip when nil.

  `base_url` is a host with no path: `wss://`, or `ws://` on loopback only.
  Raises `ArgumentError` on a value `check_subscription/2` refuses or a bad base
  URL; config validation is where the owner sees those sentences.
  """
  @spec subscribe_url(String.t(), [String.t()], [String.t()], pos_integer() | nil) :: String.t()
  def subscribe_url(base_url, dids, collections, cursor_us)
      when is_binary(base_url) and is_list(dids) and is_list(collections) and
             (is_nil(cursor_us) or (is_integer(cursor_us) and cursor_us >= @min_time_cursor)) do
    case check_subscription(dids, collections) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, message
    end

    query =
      [{"kinds", "commit"}] ++
        Enum.map(dids, &{"dids", &1}) ++
        Enum.map(collections, &{"collections", &1}) ++
        if(cursor_us, do: [{"cursor", Integer.to_string(cursor_us)}], else: [])

    base!(base_url) <> @subscribe_path <> "?" <> URI.encode_query(query, :rfc3986)
  end

  @doc """
  Decodes one text frame. `followed` is the set of DIDs the source follows.

    * `{:item, fields, time_us}`: a `create` commit by a followed account, as
      `Cues.Item.new/2` input: identity the record's `at://did/collection/rkey`
      URI, revision "1", type the collection, subject the author's DID,
      `occurred_at` the event time, data the record as sent, title the first
      line of its text.
    * `{:skip, reason, time_us}`: anything else that is a valid event (an
      update, a delete, an identity, account or sync event, an unknown kind, a
      create by an account outside `followed`); `time_us` is the event time.
      An `#info` frame skips as `{:info, name}` with time nil; `OutdatedCursor`
      means the resume point was clamped and events may have been missed.
    * `{:error, reason}`: a frame over 128 KiB, not JSON, not a v2 frame, or
      the server's terminal error frame (`{:stream_error, name}`).
  """
  @spec decode(binary(), MapSet.t(String.t())) :: decoded()
  def decode(frame, %MapSet{}) when is_binary(frame) and byte_size(frame) > @max_frame_bytes,
    do: {:error, :frame_too_large}

  def decode(frame, %MapSet{} = followed) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, envelope} -> envelope(envelope, followed)
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
    end
  end

  defp envelope(%{"$type" => "message", "payload" => %{"$type" => type} = payload}, followed)
       when is_binary(type),
       do: message(type, payload, followed)

  defp envelope(%{"$type" => "error", "error" => name}, _followed) when is_binary(name),
    do: {:error, {:stream_error, String.slice(name, 0, @max_name_chars)}}

  defp envelope(_other, _followed), do: {:error, :invalid_frame}

  defp message(@info, %{"name" => name}, _followed) when is_binary(name),
    do: {:skip, {:info, String.slice(name, 0, @max_name_chars)}, nil}

  defp message(@info, _payload, _followed), do: {:error, :invalid_frame}

  defp message(type, payload, followed) do
    case event_time(payload) do
      {:ok, time_us} -> event(type, payload, time_us, followed)
      :error -> {:error, :invalid_frame}
    end
  end

  defp event(@commit, payload, time_us, followed), do: commit(payload, time_us, followed)

  defp event(type, _payload, time_us, _followed),
    do: {:skip, Map.get(@skipped_kinds, type, :unknown_kind), time_us}

  defp commit(%{"operation" => "create"} = payload, time_us, followed) do
    case created(payload) do
      {:ok, did, fields} -> followed_item(did, fields, time_us, followed)
      :error -> {:error, :invalid_frame}
    end
  end

  defp commit(%{"operation" => "update"}, time_us, _followed), do: {:skip, :update, time_us}
  defp commit(%{"operation" => "delete"}, time_us, _followed), do: {:skip, :delete, time_us}
  defp commit(_payload, time_us, _followed), do: {:skip, :unknown_operation, time_us}

  defp followed_item(did, fields, time_us, followed) do
    if MapSet.member?(followed, did),
      do: {:item, fields, time_us},
      else: {:skip, :not_followed, time_us}
  end

  defp created(
         %{"did" => did, "collection" => collection, "rkey" => rkey, "record" => %{} = record} =
           payload
       )
       when is_binary(did) and is_binary(collection) and is_binary(rkey) do
    if did?(did) and Regex.match?(@nsid, collection) and Regex.match?(@rkey, rkey),
      do: {:ok, did, fields(payload, record)},
      else: :error
  end

  defp created(_payload), do: :error

  defp fields(%{"did" => did, "collection" => collection, "rkey" => rkey, "time" => time}, record) do
    {:ok, occurred_at, _offset} = DateTime.from_iso8601(time)

    %{
      item_id: "at://#{did}/#{collection}/#{rkey}",
      revision: "1",
      type: collection,
      subject: did,
      occurred_at: occurred_at,
      datacontenttype: "application/json",
      data: record,
      title: title(record)
    }
  end

  defp event_time(%{"time" => time}) when is_binary(time) do
    case DateTime.from_iso8601(time) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_unix(datetime, :microsecond)}
      {:error, _reason} -> :error
    end
  end

  defp event_time(_payload), do: :error

  defp title(%{"text" => text}) when is_binary(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> String.slice(0, @max_title_chars)
    |> case do
      "" -> nil
      line -> line
    end
  end

  defp title(_record), do: nil

  defp did?(value), do: is_binary(value) and Regex.match?(@did, value)

  defp collection?(value),
    do:
      is_binary(value) and
        (Regex.match?(@nsid, value) or Regex.match?(@collection_pattern, value))

  defp base!(base_url) do
    uri = URI.parse(base_url)

    if valid_base?(uri),
      do: String.trim_trailing(base_url, "/"),
      else:
        raise(
          ArgumentError,
          "a Jetstream base URL is wss://host (ws:// on loopback only), got: #{inspect(base_url)}"
        )
  end

  defp valid_base?(%URI{host: host, path: path, query: nil, fragment: nil, userinfo: nil} = uri)
       when is_binary(host) and host != "" and path in [nil, "/"],
       do: uri.scheme == "wss" or (uri.scheme == "ws" and host in @loopback_hosts)

  defp valid_base?(_uri), do: false
end
