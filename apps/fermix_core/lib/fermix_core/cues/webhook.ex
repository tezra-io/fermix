defmodule FermixCore.Cues.Webhook do
  @moduledoc """
  Webhook sources (M60 §6.5, §6.8, §6.10): the URL's random part, the three
  verification methods, and one verified request body turned into one item.

  Pure, except `ensure_path_secret/2`, which writes a secret and the config
  sentinel that names it. The door (`Cues.Door.Router`) reads the request,
  the body and the secrets, and calls the rest in the design's order.

  **The URL** is `/cues/hooks/<ref>/<random>`: `<random>` is 16 random bytes,
  url-safe base64, stored as the source's `path_secret` secret field. It
  exists only once `ensure_path_secret/2` makes it: when a new webhook source
  is saved on the setup page, on its Generate URL, or on the Mac app's Copy
  URL (`cues.sources.url.get`). Until then every request to the source answers
  404, and so does a wrong random part: the path is the first secret.

  **Verification**, one method per source, every comparison in constant time:

    * `hmac` — the configured `header` carries `prefix` and then the hex HMAC
      (`algorithm`: sha1, sha256 by default, or sha512) of the raw body, as
      GitHub's `X-Hub-Signature-256: sha256=<hex>`;
    * `standard_webhooks` — `webhook-id`, `webhook-timestamp` and
      `webhook-signature` (space-separated `v1,<base64>` entries, any one may
      match), the HMAC-SHA256 of `<id>.<timestamp>.<body>` under the base64
      key that follows `whsec_`; a timestamp more than 5 minutes from now is
      refused before the body is read;
    * `shared_secret` — the configured `header` carries the secret itself. It
      authenticates the sender, not the body; the door compares its digest.

  **Items.** One request is one item. Identity comes from exactly one of
  `id_header`, `id_path` and the explicit `id = "content_hash"`, or, for
  Standard Webhooks, from `webhook-id` (checked at load, never a fallback);
  type from `type_header` or `type_path`; revision, subject and time from their
  paths. The raw body's SHA-256 is the item's `body_hash`, so a captured body
  replayed under a new delivery id is a duplicate (C38). The body is JSON,
  decoded with duplicate keys refused.

  **The `github` preset** keeps a projection (event, action, repository, title,
  URL) of a body whose data is over 64 KiB, gives each item a title for its
  snapshot, and keeps a `ping` as a receipt that wakes nothing.
  """

  require Logger

  alias FermixCore.Cues.Config
  alias FermixCore.Cues.Item
  alias FermixCore.Plugins.CanonicalJson
  alias FermixCore.Setup.AccessToken
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.SecretWriter
  alias FermixCore.Setup.Wizard

  @path_prefix "/cues/hooks/"
  @path_secret_bytes 16
  @random_pattern ~r/\A[A-Za-z0-9_-]{1,128}\z/
  @timestamp_window_s 300
  @max_signatures 16
  @hmac_algorithms %{"sha1" => :sha, "sha256" => :sha256, "sha512" => :sha512}
  @algorithms @hmac_algorithms |> Map.keys() |> Enum.sort()
  @default_algorithm "sha256"
  @standard_secret_prefix "whsec_"
  @content_type "application/json"

  # `Cues.Item` refuses data whose canonical JSON is over 64 KiB.
  @max_data_bytes 65_536
  @max_title_chars 300
  @github_subjects ~w(pull_request issue discussion release workflow_run check_run check_suite deployment)

  @path_fields [:id_path, :revision_path, :type_path, :subject_path, :time_path]
  @header_fields [:header, :id_header, :type_header]
  @max_path_segments 16
  @segment ~r/^[^.\s]{1,128}$/u
  @header_name ~r/\A[A-Za-z0-9-]{1,64}\z/

  @type headers :: [{String.t(), String.t()}]
  @type presented :: String.t() | %{id: String.t(), timestamp: String.t(), signatures: String.t()}
  @type entry :: %{id: String.t() | nil, entry: Item.t() | {:error, term()}}

  # --- the URL ---------------------------------------------------------------

  @doc "The door path of a webhook source: `/cues/hooks/<ref>/<random>`."
  @spec path(String.t(), String.t()) :: String.t()
  def path(ref, random) when is_binary(ref) and is_binary(random) do
    unless Config.valid_name?(ref) and Regex.match?(@random_pattern, random) do
      raise ArgumentError, "a webhook path needs a source name and a url-safe random part"
    end

    @path_prefix <> ref <> "/" <> random
  end

  @doc """
  The door path of webhook source `ref`, made on the first call: 16 random
  bytes written through `SecretWriter` as `cue_source:<ref>:path_secret` in
  the configured store, then the source's `path_secret` sentinel saved to the
  config (through `Setup.Wizard.commit_snapshot/2`, which also applies it).
  A later call returns the same path. A sentinel whose item is gone gets a new
  random part in the store the sentinel names; a sentinel that cannot be saved
  takes its secret back out. A save the settings file's write guard refuses
  answers that guard's own term (`{:external_change, sections}`,
  `{:config_unreadable, sentence}`), as every settings write does; any other
  failure answers a sentence, and its reason goes to the log.

  Options: `:config` (the `[fermix_core.cues]` keyword; default the live one),
  `:persist` (`(ref, sentinel) -> :ok | {:error, term}`, the config save).
  """
  @spec ensure_path_secret(String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error,
             String.t() | {:external_change, [String.t()]} | {:config_unreadable, String.t()}}
  def ensure_path_secret(ref, opts \\ []) when is_binary(ref) and is_list(opts) do
    config =
      Keyword.get_lazy(opts, :config, fn -> Application.get_env(:fermix_core, :cues, []) end)

    with {:ok, source} <- url_source(ref, config),
         {:ok, random} <- path_secret(source, config, opts) do
      {:ok, path(ref, random)}
    end
  end

  @doc false
  @spec put_path_sentinel(map(), String.t(), String.t()) :: map()
  def put_path_sentinel(%{fermix_core: core} = snapshot, ref, sentinel)
      when is_binary(ref) and is_binary(sentinel) do
    cues = Keyword.get(core, :cues, [])
    sources = Keyword.get(cues, :sources, %{})
    section = Keyword.delete(Map.fetch!(sources, ref), :path_secret) ++ [path_secret: sentinel]
    cues = Keyword.put(cues, :sources, Map.put(sources, ref, section))
    %{snapshot | fermix_core: Keyword.put(core, :cues, cues)}
  end

  defp url_source(ref, config) do
    case Config.source(ref, config) do
      {:ok, %{kind: :webhook} = source} ->
        {:ok, source}

      {:ok, %{kind: kind}} ->
        {:error, "Source #{ref} is a #{kind} source; only a webhook source has a URL."}

      :error ->
        {:error, "There is no source #{ref}; save it first."}
    end
  end

  defp path_secret(%{ref: ref, secrets: %{path_secret: store}}, config, _opts) do
    case Config.secret(ref, :path_secret, config) do
      {:ok, random} -> {:ok, random}
      {:error, :missing_secret} -> store_random(ref, store)
      {:error, reason} -> failure(ref, "could not be read", reason)
    end
  end

  defp path_secret(%{ref: ref}, _config, opts) do
    store = SecretWriter.store()
    persist = Keyword.get(opts, :persist, &persist_sentinel/2)

    with {:ok, random} <- store_random(ref, store) do
      case persist.(ref, SecretWriter.sentinel_for(store)) do
        :ok -> {:ok, random}
        {:error, reason} -> unsaved(ref, store, reason)
      end
    end
  end

  defp store_random(ref, store) do
    random = Base.url_encode64(:crypto.strong_rand_bytes(@path_secret_bytes), padding: false)

    case SecretWriter.put({:cue_source, ref, :path_secret}, random, store: store) do
      :ok -> {:ok, random}
      {:error, reason} -> failure(ref, "could not be stored", reason)
    end
  end

  # The secret comes back out, so no item is left that no config names.
  defp unsaved(ref, store, reason) do
    case SecretWriter.delete({:cue_source, ref, :path_secret}, store: store) do
      :ok ->
        :ok

      {:error, delete_reason} ->
        Logger.error(
          "cue source #{ref}: an unsaved URL secret stays in the #{store} store " <>
            "(#{inspect(delete_reason)})"
        )
    end

    not_saved(ref, reason)
  end

  defp not_saved(_ref, {refusal, _detail} = reason)
       when refusal in [:external_change, :config_unreadable],
       do: {:error, reason}

  defp not_saved(ref, reason), do: failure(ref, "was not saved", reason)

  # The reason names stores and files, so it goes to the log, never the sentence.
  defp failure(ref, what, reason) do
    Logger.warning("cue source #{ref}: its URL #{what} (#{inspect(reason)})")
    {:error, "The URL for #{ref} #{what}. See the daemon log."}
  end

  # The source is checked again in the live snapshot: a save that removed it
  # since is an error, so the new secret comes back out.
  defp persist_sentinel(ref, sentinel) do
    snapshot = ConfigStore.current_snapshot()

    with :ok <- saved_source(snapshot, ref),
         {:ok, _report} <- Wizard.commit_snapshot(put_path_sentinel(snapshot, ref, sentinel)) do
      :ok
    end
  end

  defp saved_source(%{fermix_core: core}, ref) do
    sources = core |> Keyword.get(:cues, []) |> Keyword.get(:sources, %{})
    if Map.has_key?(sources, ref), do: :ok, else: {:error, :source_not_saved}
  end

  # --- configuration ---------------------------------------------------------

  @doc """
  A webhook source's own rules, on its section filled through its preset:
  `Cues.Config` calls it at load and raises with the sentence.
  """
  @spec check_config(map()) :: :ok | {:error, String.t()}
  def check_config(%{kind: :webhook, verify: verify} = filled) do
    with :ok <- whole_body(filled),
         :ok <- method_fields(verify, filled),
         :ok <- identity_fields(verify, filled),
         :ok <- one_type(filled),
         :ok <- check_paths(filled) do
      check_header_names(filled)
    end
  end

  defp whole_body(%{items_path: _path}),
    do: {:error, "a webhook item is the whole request body, so items_path does not apply"}

  defp whole_body(_filled), do: :ok

  # Whether `header` is there at all is `Cues.Config.required_fields/3`'s rule;
  # these check what the method takes.
  defp method_fields(:hmac, filled) do
    algorithm = Map.get(filled, :algorithm, @default_algorithm)

    if algorithm in @algorithms,
      do: :ok,
      else:
        {:error, "algorithm #{inspect(algorithm)} is not one of #{Enum.join(@algorithms, ", ")}"}
  end

  defp method_fields(:shared_secret, filled) do
    case present(filled, [:prefix, :algorithm]) do
      [] -> :ok
      [field | _rest] -> {:error, "shared_secret takes no #{field}"}
    end
  end

  defp method_fields(:standard_webhooks, filled) do
    case present(filled, [:header, :algorithm, :prefix]) do
      [] ->
        :ok

      [field | _rest] ->
        {:error, "Standard Webhooks fixes its headers and algorithm, so #{field} does not apply"}
    end
  end

  defp identity_fields(:standard_webhooks, filled) do
    case present(filled, Config.identity_fields()) do
      [] ->
        :ok

      [field | _rest] ->
        {:error,
         "a Standard Webhooks source takes its identity from webhook-id, so #{field} does not apply"}
    end
  end

  # Whether it names one at all is `Cues.Config.missing_identity?/4`'s rule;
  # this checks that it names no more than one.
  defp identity_fields(_method, filled) do
    case present(filled, Config.identity_fields()) do
      [_first, _second | _rest] = several ->
        {:error, "takes one identity, and this one names #{Enum.join(several, " and ")}"}

      _none_or_one ->
        :ok
    end
  end

  defp one_type(%{type_header: _header, type_path: _path}),
    do: {:error, "takes its type from type_header or type_path, not both"}

  defp one_type(_filled), do: :ok

  defp check_paths(filled) do
    case Enum.find(present(filled, @path_fields), &(not valid_path?(Map.fetch!(filled, &1)))) do
      nil ->
        :ok

      field ->
        {:error, "#{field} #{inspect(Map.fetch!(filled, field))} is not a dot path of keys"}
    end
  end

  defp check_header_names(filled) do
    case Enum.find(present(filled, @header_fields), &(not header_name?(Map.fetch!(filled, &1)))) do
      nil -> :ok
      field -> {:error, "#{field} #{inspect(Map.fetch!(filled, field))} is not a header name"}
    end
  end

  defp present(filled, fields), do: Enum.filter(fields, &Map.has_key?(filled, &1))

  defp valid_path?("."), do: true

  defp valid_path?(path) when is_binary(path) do
    segments = String.split(path, ".")
    length(segments) <= @max_path_segments and Enum.all?(segments, &Regex.match?(@segment, &1))
  end

  defp header_name?(name), do: is_binary(name) and Regex.match?(@header_name, name)

  # --- verification ----------------------------------------------------------

  @doc """
  What the request presents for its source's method, read from its headers
  before the body: the signature header's value (`hmac`, `shared_secret`), or
  Standard Webhooks' id, timestamp and signatures with the timestamp checked
  against `now`. An absent, repeated, empty or malformed header is
  `:missing_signature`.
  """
  @spec presented(Config.source(), headers(), DateTime.t()) ::
          {:ok, presented()} | {:error, :missing_signature | :outside_window}
  def presented(%{verify: :standard_webhooks}, headers, %DateTime{} = now)
      when is_list(headers) do
    with {:ok, id} <- header(headers, "webhook-id"),
         {:ok, stamp} <- header(headers, "webhook-timestamp"),
         {:ok, signatures} <- header(headers, "webhook-signature"),
         {:ok, seconds} <- unix_seconds(stamp) do
      within_window(seconds, now, %{id: id, timestamp: stamp, signatures: signatures})
    else
      :error -> {:error, :missing_signature}
    end
  end

  def presented(%{verify: verify, header: name}, headers, %DateTime{})
      when verify in [:hmac, :shared_secret] and is_binary(name) and is_list(headers) do
    case header(headers, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :missing_signature}
    end
  end

  defp unix_seconds(stamp) do
    case Integer.parse(stamp) do
      {seconds, ""} -> {:ok, seconds}
      _not_seconds -> :error
    end
  end

  defp within_window(seconds, now, presented) do
    if abs(DateTime.to_unix(now) - seconds) <= @timestamp_window_s,
      do: {:ok, presented},
      else: {:error, :outside_window}
  end

  @doc """
  Checks a signed method (`hmac`, `standard_webhooks`) over the raw `body`
  with the source's `secret`. `:bad_secret` means the stored secret is not one
  the method can use (a Standard Webhooks secret that is not base64): the
  source's fault, not the request's.
  """
  @spec verify(Config.source(), presented(), binary(), String.t()) ::
          :ok | {:error, :bad_signature | :bad_secret}
  def verify(%{verify: :hmac} = source, presented, body, secret)
      when is_binary(presented) and is_binary(body) and is_binary(secret) do
    prefix = source.prefix || ""
    expected = :crypto.mac(:hmac, hmac_algorithm(source), secret, body)

    with true <- String.starts_with?(presented, prefix),
         hex = binary_part(presented, byte_size(prefix), byte_size(presented) - byte_size(prefix)),
         {:ok, mac} <- Base.decode16(hex, case: :mixed),
         true <- AccessToken.secure_equal?(mac, expected) do
      :ok
    else
      _mismatch -> {:error, :bad_signature}
    end
  end

  def verify(%{verify: :standard_webhooks}, %{} = presented, body, secret)
      when is_binary(body) and is_binary(secret) do
    case standard_key(secret) do
      {:ok, key} ->
        signed = [presented.id, ".", presented.timestamp, ".", body]
        expected = :crypto.mac(:hmac, :sha256, key, signed)

        matched? =
          Enum.any?(v1_signatures(presented.signatures), &AccessToken.secure_equal?(&1, expected))

        if matched?, do: :ok, else: {:error, :bad_signature}

      :error ->
        {:error, :bad_secret}
    end
  end

  defp hmac_algorithm(source),
    do: Map.fetch!(@hmac_algorithms, source.algorithm || @default_algorithm)

  defp standard_key(secret) do
    case secret
         |> String.replace_prefix(@standard_secret_prefix, "")
         |> Base.decode64(padding: false) do
      {:ok, key} when key != "" -> {:ok, key}
      _not_a_key -> :error
    end
  end

  defp v1_signatures(header) do
    header
    |> String.split(" ", trim: true)
    |> Enum.take(@max_signatures)
    |> Enum.flat_map(fn
      "v1," <> encoded -> decoded_signature(encoded)
      _other_version -> []
    end)
  end

  defp decoded_signature(encoded) do
    case Base.decode64(encoded, padding: false) do
      {:ok, signature} -> [signature]
      :error -> []
    end
  end

  # --- items -----------------------------------------------------------------

  @doc """
  The item a verified request carries: `%{id: id, entry: entry}`, where
  `entry` is what `Cues.Ingest.accept/3` takes (the item, or why it is not
  one) and `id` the item id the door answers with. A body that is not JSON,
  or repeats a key, is refused as a request.
  """
  @spec entry(Config.source(), headers(), binary(), DateTime.t()) ::
          {:ok, entry()} | {:error, term()}
  def entry(%{kind: :webhook} = source, headers, body, %DateTime{} = now)
      when is_list(headers) and is_binary(body) do
    with {:ok, data} <- decode(body) do
      fields = fields(source, headers, data, body)
      {:ok, build(fields, identity(source, headers, data), now)}
    end
  end

  defp decode(body) do
    case CanonicalJson.decode(body) do
      {:ok, decoded} -> {:ok, plain(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fields(source, headers, data, body) do
    type = item_type(source, headers, data)
    github? = source.preset == "github"

    %{
      revision: scalar_at(data, source.revision_path) || "1",
      type: type,
      subject: scalar_at(data, source.subject_path),
      occurred_at: time_at(data, source.time_path),
      datacontenttype: @content_type,
      data: if(github?, do: github_data(data, type), else: data),
      title: if(github?, do: github_title(data)),
      body_hash: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower),
      receipt_only?: github? and type == "ping"
    }
  end

  defp identity(%{verify: :standard_webhooks}, headers, _data),
    do: header_value(headers, "webhook-id")

  defp identity(%{id_header: name}, headers, _data) when is_binary(name),
    do: header_value(headers, name)

  defp identity(%{id_path: path}, _headers, data) when is_binary(path), do: scalar_at(data, path)
  defp identity(%{id: :content_hash}, _headers, _data), do: :content_hash

  defp item_type(%{type_header: name}, headers, _data) when is_binary(name),
    do: header_value(headers, name)

  defp item_type(%{type_path: path}, _headers, data) when is_binary(path),
    do: scalar_at(data, path)

  defp item_type(_source, _headers, _data), do: nil

  # A content_hash id is the item's own content hash, so `Cues.Item` keeps
  # the one definition of what that hash covers.
  defp build(fields, :content_hash, now) do
    case Item.new(Map.put(fields, :item_id, "content_hash"), now) do
      {:ok, probe} -> build(fields, "sha256:" <> probe.content_hash, now)
      {:error, _reason} = refused -> %{id: nil, entry: refused}
    end
  end

  defp build(fields, id, now) do
    case Item.new(Map.put(fields, :item_id, id), now) do
      {:ok, item} -> %{id: id, entry: item}
      {:error, _reason} = refused -> %{id: id, entry: refused}
    end
  end

  # --- github ----------------------------------------------------------------

  defp github_data(data, type) do
    if canonical_bytes(data) > @max_data_bytes, do: github_projection(data, type), else: data
  end

  # Data that cannot be canonicalised is left whole: `Cues.Item` refuses it
  # with its own sentence.
  defp canonical_bytes(data) do
    case CanonicalJson.encode(data) do
      {:ok, text} -> byte_size(text)
      {:error, _reason} -> 0
    end
  end

  defp github_projection(data, type) do
    %{
      "projected" => true,
      "event" => type,
      "action" => string_at(data, ["action"]),
      "repository" => string_at(data, ["repository", "full_name"]),
      "title" => github_title(data),
      "url" => github_url(data)
    }
  end

  defp github_title(data) do
    subject = github_subject(data)
    title = string_at(subject, ["title"]) || string_at(subject, ["name"])

    case title || first_line(string_at(data, ["head_commit", "message"])) do
      nil -> nil
      text -> String.slice(text, 0, @max_title_chars)
    end
  end

  defp github_url(data) do
    string_at(data, ["comment", "html_url"]) ||
      string_at(github_subject(data), ["html_url"]) ||
      string_at(data, ["compare"]) ||
      string_at(data, ["repository", "html_url"])
  end

  defp github_subject(%{} = data),
    do: Enum.find_value(@github_subjects, &object_at(data, &1))

  defp github_subject(_data), do: nil

  defp object_at(data, key) do
    case Map.get(data, key) do
      %{} = object -> object
      _absent -> nil
    end
  end

  defp first_line(nil), do: nil

  defp first_line(text) do
    text |> String.split("\n", parts: 2) |> hd() |> String.trim() |> blank_to_nil()
  end

  # --- values ----------------------------------------------------------------

  defp header(headers, name) do
    wanted = String.downcase(name)

    case for({key, value} <- headers, key == wanted, do: value) do
      [value] when value != "" -> {:ok, value}
      _none_or_several -> :error
    end
  end

  defp header_value(headers, name) do
    case header(headers, name) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp string_at(value, keys) do
    case get_path(value, keys) do
      text when is_binary(text) and text != "" -> text
      _other -> nil
    end
  end

  defp get_path(value, []), do: value
  defp get_path(%{} = object, [key | rest]), do: object |> Map.get(key) |> get_path(rest)
  defp get_path(_value, _keys), do: nil

  defp scalar_at(_data, nil), do: nil

  defp scalar_at(data, path) do
    case lookup(data, path) do
      {:ok, value} when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      {:ok, value} when is_integer(value) -> Integer.to_string(value)
      _other -> nil
    end
  end

  defp time_at(data, path) do
    with text when is_binary(text) <- scalar_at(data, path),
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      at
    else
      _absent_or_unparsed -> nil
    end
  end

  # Segments are bounded by `check_config/1`, so the walk is too.
  defp lookup(data, "."), do: {:ok, data}

  defp lookup(data, path),
    do: path |> String.split(".") |> Enum.reduce_while({:ok, data}, &step/2)

  defp step(key, {:ok, %{} = object}) do
    case Map.fetch(object, key) do
      {:ok, value} -> {:cont, {:ok, value}}
      :error -> {:halt, :error}
    end
  end

  defp step(key, {:ok, list}) when is_list(list) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 and index < length(list) -> {:cont, {:ok, Enum.at(list, index)}}
      _other -> {:halt, :error}
    end
  end

  defp step(_key, _acc), do: {:halt, :error}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  # Keys are unique once `CanonicalJson.decode/1` accepted the body.
  defp plain(%Jason.OrderedObject{values: pairs}),
    do: Map.new(pairs, fn {key, value} -> {key, plain(value)} end)

  defp plain(values) when is_list(values), do: Enum.map(values, &plain/1)
  defp plain(value), do: value
end
