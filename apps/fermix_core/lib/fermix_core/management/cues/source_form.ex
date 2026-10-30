defmodule FermixCore.Management.Cues.SourceForm do
  @moduledoc """
  The source form of the management socket (M60 app surface §3.3, §4.3): what
  `cues.sources.form` offers for a kind, preset and verification method, the
  editable fields `cues.sources.get` publishes as `values`, and the
  translation of a form's `values` into the section `Cues.Settings` saves.

  The form is the daemon's: a client draws its `rows` with the descriptor
  rows Settings uses and writes no field list per kind. A field a preset
  fills is published with the preset's value under More options (`advanced`),
  as is one whose purpose the preset settles another way (an identity, a
  type), and a value equal to it is not written, so the section stays as
  short as a hand edit would be. `Cues.Config.normalize/1` is still the one that accepts
  or refuses a section; this module only shapes the values and refuses what
  is not a field of the form.

  A secret is never a value: a secret row is published with its presence,
  and its value crosses in `secret.set` alone. A webhook has one secret row,
  last; a stream with no preset (the general WebSocket source) has two, `key`
  and `secret` (API key and API secret, the names the source's page gives
  them), each with its own presence, straight after the address. That
  stream's rows are its own: the address, how it signs in, where each message
  keeps its id and type, and, under More options, the rest of its paths, each
  with an `info` saying what it is for, behind an info control like every cue
  row's explanation (no footers), and an `example` the empty field shows.

  A feed with the X accounts preset has no address to type and no secret: its
  one field is its handles (`handles_row/0`), kept as `Cues.XAccounts.handles/1`
  keeps them, and its note says it reads with the X plugin's sign-in
  (`preset_note/1`).

  The add form starts from what the owner wants watched (M60 simpler setup
  §3, §7): every answer carries the same `choices` (`choices/0`), each a kind
  and a preset, the featured ones first. A choice's form opens only what it
  needs (`add_open_keys/3`) and folds the rest under More options, the name
  first among them: left empty, Fermix names the source (`name_row/1`,
  `Cues.SourceName`). GitHub's add form has no secret row, since Fermix makes
  that secret, and X accounts carries a `requirement` saying whether the X
  sign-in is there (`requirement/2`). The edit form keeps its rows and folds.
  Every word is here, so the browser setup page reads the same ones.
  """

  alias FermixCore.Cues.Config, as: CuesConfig
  alias FermixCore.Cues.Presets
  alias FermixCore.Cues.XAccounts
  alias FermixCore.Management.Settings.Row

  @kinds [
    %{
      id: "feed",
      label: "Feed",
      sentence: "Fermix asks a site for new items on a schedule."
    },
    %{
      id: "stream",
      label: "Stream",
      sentence:
        "Fermix keeps a connection open to a WebSocket (wss://) address and takes items as " <>
          "they arrive."
    },
    %{
      id: "webhook",
      label: "Webhook",
      sentence: "A service sends items to an address Fermix makes when you add this source."
    },
    %{
      id: "local_push",
      label: "Local push",
      sentence: "Scripts on this Mac send items with a token made when you add this source."
    }
  ]
  @kind_ids Enum.map(@kinds, & &1.id)
  @preset_labels %{
    "rss" => "RSS, Atom or JSON Feed",
    "github" => "GitHub",
    "x_accounts" => "X accounts"
  }
  @verify_options [
    {"hmac", "A signature over the body"},
    {"standard_webhooks", "Standard Webhooks"},
    {"shared_secret", "A shared secret in a header"}
  ]
  @verify_ids Enum.map(@verify_options, &elem(&1, 0))
  @algorithms ~w(sha256 sha512 sha1)

  @consent %{
    "feed" => "Fermix asks this address for new items on the schedule you set.",
    "stream" => "Fermix keeps a connection open to this address and takes every item it sends.",
    "webhook" => "A service that has this source's address and its secret can send it items.",
    "local_push" => "A program on this Mac that has the token can send this source items."
  }
  @webhook_note "The door listens on this Mac only. A service outside reaches it through a " <>
                  "tunnel you run."
  @github_note "In GitHub's webhook form, choose `application/json` as the content type."
  @x_accounts_consent "Fermix asks X for these accounts' new posts on the schedule you set."
  @x_accounts_note "Reads with your X sign-in from the X plugin. Connect X under Plugins " <>
                     "first. X bills your X app for each post it returns."
  @handles_row %{
    label: "Accounts",
    info: "X usernames, with or without @. Up to 20.",
    example: "nasa"
  }

  # What the owner wants watched, in the order a client lists them: the
  # featured ones first, the rest under "Something else".
  @choices [
    %{
      id: "rss",
      label: "Website or blog",
      sentence: "New posts from a site's RSS, Atom or JSON feed.",
      kind: "feed",
      preset: "rss",
      featured: true
    },
    %{
      id: "x_accounts",
      label: "X accounts",
      sentence: "New posts from accounts you choose. Uses your X sign-in.",
      kind: "feed",
      preset: "x_accounts",
      featured: true
    },
    %{
      id: "github",
      label: "GitHub",
      sentence: "Pushes, issues and pull requests. Needs a tunnel to this computer.",
      kind: "webhook",
      preset: "github",
      featured: true
    },
    %{
      id: "local_push",
      label: "Your scripts",
      sentence: "Programs on this computer send items with a token.",
      kind: "local_push",
      preset: nil,
      featured: true
    },
    %{
      id: "feed",
      label: "Any feed address",
      sentence: "Fermix checks an address on a schedule.",
      kind: "feed",
      preset: nil,
      featured: false
    },
    %{
      id: "stream",
      label: "Live stream",
      sentence: "Fermix keeps a WebSocket connection open and takes items as they arrive.",
      kind: "stream",
      preset: nil,
      featured: false
    },
    %{
      id: "webhook",
      label: "Any webhook",
      sentence: "A service sends items to an address Fermix makes.",
      kind: "webhook",
      preset: nil,
      featured: false
    }
  ]
  @choice_ids Enum.map(@choices, & &1.id)

  # The rows a choice's add form opens beside the fields its kind needs and
  # no preset fills (`Cues.Config.required_fields/3`) and the identity a
  # signed webhook needs; every other row is under More options.
  @add_open %{
    "rss" => ~w(url),
    "x_accounts" => ~w(handles),
    "github" => [],
    "local_push" => [],
    "feed" => ~w(url interval_minutes),
    "stream" => ~w(url key secret subscribe_message id_path),
    "webhook" => ~w(verify secret)
  }

  @name_label "Name"
  @name_info "How you and Fermix refer to it in chat. Left empty, Fermix names it from " <>
               "what you enter."
  # What `Cues.SourceName` makes for each choice, shown in the empty field.
  @name_examples %{
    "rss" => "ycombinator",
    "x_accounts" => "x-nasa",
    "github" => "github",
    "local_push" => "scripts",
    "feed" => "weatherdesk",
    "stream" => "marketwire",
    "webhook" => "webhook"
  }

  @x_signed_in "Signed in to X."
  @x_needs_sign_in "Connect X to read these accounts."

  @feed_address_label "Feed address"
  @address_label "Address"
  @secret_label "Secret"
  @shared_secret_label "Shared secret"
  # The words of every row a feed, a webhook or a local push draws, but its
  # address, handles and secret.
  @field_words %{
    "interval_minutes" => %{label: "Check every", info: nil},
    "daily_budget" => %{label: "Daily limit", info: "The most items a day. 0 means no limit."},
    "verify" => %{label: "Verification", info: nil},
    "header" => %{label: "Signature header", info: nil},
    "algorithm" => %{label: "Algorithm", info: nil},
    "prefix" => %{label: "Signature prefix", info: nil},
    "id_header" => %{label: "Delivery id header", info: nil},
    "content_hash" => %{
      label: "Identify items by their content",
      info: "For a service that sends no delivery id: an exact repeat is a duplicate."
    },
    "type_header" => %{label: "Event type header", info: nil}
  }
  @push_note "Send each item as a CloudEvent, with the token as a bearer token."
  @general_stream_note "Any WebSocket service. Fermix signs in with your API key and secret, " <>
                         "sends the subscribe message, and keeps each message of a type you list."
  @secret_info "Stored in your keychain and never shown again."

  @unknown_field "This source has no setting by that name."
  @needed "Needed when no preset fills it."
  @no_identity "Give a delivery id header, or have Fermix identify items by their content."
  @secret_value "This is a secret. Store it with secret.set instead."
  @single_line "This setting takes a single line of text."
  @published_value "This setting takes one of its published values."
  @max_list_items 200

  # Each field the form knows: its row key, its key in the section, the row
  # kind, and the kinds it applies to. `Cues.Config` holds the same rule.
  @fields [
    %{key: "url", config: :url, kind: :text, kinds: [:feed, :stream]},
    %{key: "handles", config: :handles, kind: :list, kinds: [:feed]},
    %{key: "interval_minutes", config: :interval, kind: :number, kinds: [:feed]},
    %{key: "key_header", config: :key_header, kind: :text, kinds: [:stream]},
    %{key: "secret_header", config: :secret_header, kind: :text, kinds: [:stream]},
    %{key: "auth_message", config: :auth_message, kind: :text, kinds: [:stream]},
    %{key: "subscribe_message", config: :subscribe_message, kind: :text, kinds: [:stream]},
    %{key: "id_path", config: :id_path, kind: :text, kinds: [:stream]},
    %{key: "type_path", config: :type_path, kind: :text, kinds: [:stream]},
    %{key: "item_types", config: :item_types, kind: :list, kinds: [:stream]},
    %{key: "error_types", config: :error_types, kind: :list, kinds: [:stream]},
    %{key: "items_path", config: :items_path, kind: :text, kinds: [:stream]},
    %{key: "revision_path", config: :revision_path, kind: :text, kinds: [:stream]},
    %{key: "time_path", config: :time_path, kind: :text, kinds: [:stream]},
    %{key: "subject_path", config: :subject_path, kind: :text, kinds: [:stream]},
    %{key: "verify", config: :verify, kind: :choice, kinds: [:webhook]},
    %{key: "header", config: :header, kind: :text, kinds: [:webhook]},
    %{key: "algorithm", config: :algorithm, kind: :choice, kinds: [:webhook]},
    %{key: "prefix", config: :prefix, kind: :text, kinds: [:webhook]},
    %{key: "id_header", config: :id_header, kind: :text, kinds: [:webhook]},
    %{key: "content_hash", config: :id, kind: :toggle, kinds: [:webhook]},
    %{key: "type_header", config: :type_header, kind: :text, kinds: [:webhook]},
    %{
      key: "daily_budget",
      config: :daily_budget,
      kind: :number,
      kinds: [:feed, :stream, :webhook, :local_push]
    }
  ]
  @field_by_key Map.new(@fields, &{&1.key, &1})

  # A stream with no preset: its rows in form order, the ones most sources need
  # first, each with its label, its info (kept behind an info control) and its
  # example (shown in the empty field). No two labels read alike, and a field
  # that names where a value goes says so ("Header name for…", "… field"), so
  # it is not taken for the value. A literal the owner types is backticked in
  # an info, the copy rules' mark for one. The examples are invented and short
  # enough for the field. `general_stream_rows/0` publishes them, so the
  # browser setup page draws the same rows in the same words.
  @general_rows [
    {"url", "Address", "The service's WebSocket address. It starts with `wss://`.",
     "wss://news.example.com/stream"},
    {"key_header", "Header name for the API key",
     "If the service reads your API key from a header when connecting, that header's name. " <>
       "The key itself goes in API key. Leave it empty if the service does not use one.",
     "X-Api-Key"},
    {"secret_header", "Header name for the API secret",
     "If the service reads your API secret from a header when connecting, that header's " <>
       "name. The secret itself goes in API secret. Leave it empty if the service does not " <>
       "use one.", "X-Api-Secret"},
    {"auth_message", "Sign-in message",
     "For a service that signs in by a message instead of headers: JSON on one line, sent " <>
       "first. Fermix puts your API key where it says `{{key}}` and your API secret where " <>
       "it says `{{secret}}`.", ~s({"auth":"{{key}}"})},
    {"subscribe_message", "Subscribe message",
     "JSON on one line, sent after signing in, that tells the service what to send.",
     ~s({"subscribe":"news"})},
    {"id_path", "Id field",
     "Where each message keeps its unique id, so a message sent twice becomes one item. A " <>
       "dotted path reaches inside a message, such as `data.id`.", "id"},
    {"type_path", "Type field", "Where each message says what kind of message it is.", "type"},
    {"item_types", "Types to keep",
     "Messages of these types become items. Leave it empty to keep every message.", "news"},
    {"error_types", "Error types",
     "A message of one of these types is the service refusing: Fermix closes the connection " <>
       "and tries again.", "error"},
    {"items_path", "List field",
     "Where a frame keeps a list of messages, read one message at a time.", "data"},
    {"revision_path", "Revision field",
     "Where an updated message keeps its revision, so an edit becomes a new version of the " <>
       "same item.", "updated_at"},
    {"time_path", "Time field", "Where each message keeps its time.", "created_at"},
    {"subject_path", "Subject field", "Where each message keeps what it is about.", "tickers.0"}
  ]
  @general_stream_keys Enum.map(@general_rows, &elem(&1, 0)) ++ ["daily_budget"]
  @general_row_words Map.new(@general_rows, fn {key, label, info, example} ->
                       {key, {label, info, example}}
                     end)
  @more_options [:daily_budget, :items_path, :revision_path, :time_path, :subject_path]

  @type kind :: String.t()
  @type refusal :: {String.t(), String.t()}

  @doc "Every kind a source can be, as the form's segmented control lists them."
  @spec kinds() :: [map()]
  def kinds,
    do: Enum.map(@kinds, &%{"id" => &1.id, "label" => &1.label, "sentence" => &1.sentence})

  @doc "Every preset, with the kind it makes."
  @spec presets() :: [map()]
  def presets do
    for name <- Presets.names() do
      {:ok, %{kind: kind}} = Presets.defaults(name)
      %{"id" => name, "label" => preset_label(name), "kind" => Atom.to_string(kind)}
    end
  end

  @doc "A kind's name as a row shows it."
  @spec kind_label(atom() | String.t()) :: String.t()
  def kind_label(kind) do
    id = to_string(kind)
    Enum.find_value(@kinds, id, &(&1.id == id && &1.label))
  end

  @doc """
  The rows of a stream with no preset before its daily budget, in form order:
  each field's config key, row kind (`:text` or `:list`), label, info, example
  and whether it sits under More options on the edit form (an add form opens
  `add_open_keys/3`). The browser setup page draws its form from these, so
  both surfaces say the same thing.
  """
  @spec general_stream_rows() :: [
          %{
            field: atom(),
            kind: :text | :list,
            label: String.t(),
            info: String.t(),
            example: String.t(),
            advanced: boolean()
          }
        ]
  def general_stream_rows do
    for {key, label, info, example} <- @general_rows do
      %{config: config, kind: kind} = Map.fetch!(@field_by_key, key)

      %{
        field: config,
        kind: kind,
        label: label,
        info: info,
        example: example,
        advanced: config in @more_options
      }
    end
  end

  @doc """
  The handles row of an X accounts source: its label, info and example. The
  browser setup page draws its field from these, so both surfaces say the
  same thing.
  """
  @spec handles_row() :: %{label: String.t(), info: String.t(), example: String.t()}
  def handles_row, do: @handles_row

  @doc """
  The note a feed preset's form carries, or nil: X accounts says it reads
  with the X plugin's sign-in and that X bills for what it returns.
  """
  @spec preset_note(String.t() | nil) :: String.t() | nil
  def preset_note("x_accounts"), do: @x_accounts_note
  def preset_note(_preset), do: nil

  @doc """
  The sentence a preset says where its items come from in, or nil when its
  kind's says it: X accounts asks X, not an address the owner gave. The form's
  `consent_sentence` and the browser setup page's kind line read it.
  """
  @spec preset_consent(String.t() | nil) :: String.t() | nil
  def preset_consent("x_accounts"), do: @x_accounts_consent
  def preset_consent(_preset), do: nil

  @doc "A preset's name as a row shows it."
  @spec preset_label(String.t()) :: String.t()
  def preset_label(name) when is_binary(name), do: Map.get(@preset_labels, name, name)

  @doc """
  What the owner can ask Fermix to watch, in the order a client lists them:
  each with its `id`, `label`, `sentence`, the `kind` and `preset` (or nil)
  its form takes, and whether it is `featured` (drawn first; the rest under
  "Something else"). The same on every form.
  """
  @spec choices() :: [map()]
  def choices do
    for choice <- @choices do
      %{
        "id" => choice.id,
        "label" => choice.label,
        "sentence" => choice.sentence,
        "kind" => choice.kind,
        "preset" => choice.preset,
        "featured" => choice.featured
      }
    end
  end

  @doc """
  What choice `id` needs set up first, or nil. Only X accounts has one: the
  X plugin's sign-in, read as the source reads it
  (`Cues.XAccounts.sign_in_state/1`), `ready` or `needs_sign_in`. It never
  stops the add. `opts`: `:x_sign_in`, a zero-arity function answering in the
  sign-in's place.
  """
  @spec requirement(String.t(), keyword()) :: %{String.t() => String.t()} | nil
  def requirement("x_accounts", opts) when is_list(opts) do
    sign_in = Keyword.get(opts, :x_sign_in, &XAccounts.sign_in_state/0)

    # Every reason the sign-in is not ready is a sign-in for the owner to make.
    case sign_in.() do
      :ready -> x_requirement("ready", @x_signed_in)
      {:error, _reason} -> x_requirement("needs_sign_in", @x_needs_sign_in)
    end
  end

  def requirement(id, opts) when id in @choice_ids and is_list(opts), do: nil

  defp x_requirement(state, sentence),
    do: %{"state" => state, "sentence" => sentence, "plugin" => "x"}

  @doc """
  The name row of choice `id`'s add form: its label, its info, and the name
  Fermix would make for it, which the empty field shows.
  """
  @spec name_row(String.t()) :: %{label: String.t(), info: String.t(), example: String.t()}
  def name_row(id) when id in @choice_ids,
    do: %{label: @name_label, info: @name_info, example: Map.fetch!(@name_examples, id)}

  @doc """
  The row keys choice `kind` and `preset` opens on the add form with
  verification `method` (nil for none): its own, the fields it needs that no
  preset fills, and a signed webhook's identity. Every other row of the form
  is under More options.
  """
  @spec add_open_keys(String.t(), String.t() | nil, String.t() | nil) :: [String.t()]
  def add_open_keys(kind, preset, method) when kind in @kind_ids do
    atom = String.to_existing_atom(kind)
    needed = atom |> CuesConfig.required_fields(preset, method) |> Enum.map(&row_key/1)

    identity =
      if CuesConfig.missing_identity?(atom, preset, method, []),
        do: ~w(id_header content_hash),
        else: []

    Enum.uniq(Map.fetch!(@add_open, preset || kind) ++ needed ++ identity)
  end

  @doc """
  The label and info of a feed's, webhook's or local push's row `key`: one
  of `interval_minutes`, `daily_budget`, `verify`, `header`, `algorithm`,
  `prefix`, `id_header`, `content_hash` and `type_header`.
  """
  @spec field_words(String.t()) :: %{label: String.t(), info: String.t() | nil}
  def field_words(key) when is_map_key(@field_words, key), do: Map.fetch!(@field_words, key)

  @doc ~s(The address row's label: "Feed address" for a website or blog, else "Address".)
  @spec url_label(String.t() | nil) :: String.t()
  def url_label("rss"), do: @feed_address_label
  def url_label(_preset), do: @address_label

  @doc "A webhook's secret row's label for verification `method`."
  @spec webhook_secret_label(String.t() | nil) :: String.t()
  def webhook_secret_label("shared_secret"), do: @shared_secret_label
  def webhook_secret_label(_method), do: @secret_label

  @doc """
  The add form for a choice of kind, preset and verification method, each
  optional. A preset decides the kind; one that contradicts the kind sent is
  refused, as is a kind, preset or method this daemon does not know. `opts`
  are `requirement/2`'s.
  """
  @spec form(String.t() | nil, String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, refusal()}
  def form(kind, preset, verify, opts \\ []) when is_list(opts) do
    with {:ok, kind} <- resolve_kind(kind, preset),
         :ok <- known_verify(verify) do
      {:ok,
       %{
         "choices" => choices(),
         "requirement" => requirement(preset || kind, opts),
         "kinds" => kinds(),
         "presets" => presets(),
         "rows" => add_rows(kind, preset, verify),
         "consent_sentence" => preset_consent(preset) || Map.fetch!(@consent, kind),
         "notes" => notes(kind, preset)
       }}
    end
  end

  # The name first, then the fields, then the secrets the owner types; the
  # choice's own rows open and the rest under More options.
  defp add_rows(kind, preset, verify) do
    defaults = preset_defaults(preset)
    method = verify || defaults |> Map.get(:verify) |> text()
    chosen = if verify, do: [verify: verify], else: []
    fields = [name_field(preset || kind) | field_rows(kind, preset, method, defaults, chosen)]
    open = add_open_keys(kind, preset, method)

    fields
    |> with_secrets(add_secret_rows(kind, preset, method), kind, preset)
    |> Enum.map(&Map.put(&1, "advanced", &1["key"] not in open))
  end

  # Fermix makes GitHub's secret when the source is added.
  defp add_secret_rows("webhook", "github", _method), do: []
  defp add_secret_rows(kind, preset, method), do: secret_rows(kind, preset, method, %{})

  @doc """
  The editable fields of a saved source as settings rows, filled from its
  section (`section`, the persisted shape) and its preset: the add form with
  the name, kind and preset left out, since those cannot change. Each secret
  row carries its own field's presence.
  """
  @spec values(keyword(), CuesConfig.source()) :: [Row.t()]
  def values(section, source) when is_list(section) and is_map(source) do
    kind = Atom.to_string(source.kind)
    defaults = preset_defaults(source.preset)
    method = source.verify && Atom.to_string(source.verify)

    kind
    |> field_rows(source.preset, method, defaults, section)
    |> with_secrets(secret_rows(kind, source.preset, method, source.secrets), kind, source.preset)
  end

  @doc """
  The section a new source's `values` make: its preset or kind first, then
  each field in form order. Refused, with the key it names, when a value is
  not a field of this form or not the shape its row takes.
  """
  @spec new_section(String.t() | nil, String.t() | nil, map()) ::
          {:ok, keyword()} | {:error, refusal()}
  def new_section(kind, preset, values) when is_map(values) do
    with {:ok, kind} <- resolve_kind(kind, preset),
         {:ok, method} <- method(values, preset_defaults(preset)),
         {:ok, entries} <- entries(values, kind, preset, method, preset_defaults(preset)),
         filled = Enum.reject(entries, &blank_entry?/1),
         :ok <- needed(kind, preset, [{:verify, method} | filled]) do
      head = if preset, do: [preset: preset], else: [kind: kind]
      {:ok, head ++ filled}
    end
  end

  @doc """
  `section` (the persisted shape, no secret field) with `values` applied: a
  value replaces the field, and a blank text, an empty list or a switched-off
  identity removes it. A webhook whose method changes loses the fields only
  the old method takes, which the new method's form no longer shows. The
  name, kind and preset cannot change.
  """
  @spec merge(keyword(), CuesConfig.source(), map()) :: {:ok, keyword()} | {:error, refusal()}
  def merge(section, source, values) when is_list(section) and is_map(values) do
    defaults = preset_defaults(source.preset)
    kind = Atom.to_string(source.kind)
    old_method = source.verify && Atom.to_string(source.verify)

    with {:ok, method} <- method(Map.merge(%{"verify" => old_method}, values), defaults),
         {:ok, entries} <- entries(values, kind, source.preset, method, %{}),
         section = Keyword.drop(section, dropped_fields(old_method, method)),
         merged = Enum.reduce(entries, section, &apply_entry/2),
         :ok <- needed(kind, source.preset, [{:verify, method} | merged]) do
      {:ok, merged}
    end
  end

  # A field the kind needs and its preset does not fill (`Cues.Config`'s own
  # rule), left out, is refused under the form's row for it, before the
  # config's sentence would name the source instead.
  # Its identity too (`Cues.Config.missing_identity?/4`), under the delivery id
  # header's row, naming both ways out.
  defp needed(kind, preset, filled) do
    kind = String.to_existing_atom(kind)
    verify = Keyword.get(filled, :verify)

    missing =
      kind
      |> CuesConfig.required_fields(preset, verify)
      |> Enum.find(&(Keyword.get(filled, &1) in [nil, "", []]))

    cond do
      missing ->
        {:error, {row_key(missing), @needed}}

      CuesConfig.missing_identity?(kind, preset, verify, filled) ->
        {:error, {"id_header", @no_identity}}

      true ->
        :ok
    end
  end

  defp row_key(config), do: Enum.find(@fields, &(&1.config == config)).key

  defp dropped_fields(same, same), do: []

  defp dropped_fields(old_method, method) do
    (method_keys(old_method) -- method_keys(method))
    |> Enum.map(&Map.fetch!(@field_by_key, &1).config)
  end

  @doc """
  The form field a refusal of `Cues.Config` is about: the key its
  `cues.sources.<ref>.<key>` names, as a row key, else `fallback`. Only that
  prefix is read, never a free word of the sentence.
  """
  @spec field_of(String.t(), String.t()) :: String.t()
  def field_of(sentence, fallback) when is_binary(sentence) and is_binary(fallback) do
    case Regex.run(~r/cues\.sources\.[a-z0-9-]+\.([a-z_]+)/, sentence) do
      [_match, key] -> config_field(key) || fallback
      nil -> fallback
    end
  end

  defp config_field(word) do
    case Enum.find(@fields, &(Atom.to_string(&1.config) == word)) do
      nil -> nil
      field -> field.key
    end
  end

  # --- the choice --------------------------------------------------------------

  defp resolve_kind(kind, nil) when kind in @kind_ids, do: {:ok, kind}
  defp resolve_kind(nil, nil), do: {:ok, "feed"}
  defp resolve_kind(_kind, nil), do: {:error, {"kind", "Fermix has no source kind by that name."}}

  defp resolve_kind(kind, preset) do
    case Presets.defaults(preset) do
      {:ok, %{kind: made}} -> preset_kind(Atom.to_string(made), kind, preset)
      :error -> {:error, {"preset", "Fermix has no preset by that name."}}
    end
  end

  defp preset_kind(made, kind, _preset) when kind in [nil, made], do: {:ok, made}

  defp preset_kind(made, _kind, preset),
    do:
      {:error,
       {"preset", "The #{preset_label(preset)} preset makes a #{kind_label(made)} source."}}

  defp known_verify(nil), do: :ok
  defp known_verify(verify) when verify in @verify_ids, do: :ok
  defp known_verify(_verify), do: {:error, {"verify", @published_value}}

  defp method(values, defaults) do
    case Map.get(values, "verify") do
      nil -> {:ok, defaults |> Map.get(:verify) |> text()}
      verify when verify in @verify_ids -> {:ok, verify}
      _other -> {:error, {"verify", @published_value}}
    end
  end

  defp preset_defaults(nil), do: %{}

  defp preset_defaults(preset) do
    case Presets.defaults(preset) do
      {:ok, defaults} -> defaults
      :error -> %{}
    end
  end

  defp notes("webhook", "github"), do: [@webhook_note, @github_note]
  defp notes("webhook", _preset), do: [@webhook_note]
  defp notes("local_push", _preset), do: [@push_note]
  defp notes("stream", nil), do: [@general_stream_note]
  defp notes("feed", preset), do: List.wrap(preset_note(preset))
  defp notes(_kind, _preset), do: []

  # --- rows --------------------------------------------------------------------

  defp name_field(choice) do
    words = name_row(choice)

    Row.new("ref", :text, words.label,
      info: words.info,
      example: words.example,
      value: "",
      advanced: true,
      restart: restart()
    )
  end

  defp field_rows(kind, preset, method, defaults, section) do
    build =
      if general_stream?(kind, preset),
        do: &general_row/3,
        else: &field_row(&1, &2, &3, preset)

    for field <- shown(kind, preset, method),
        do: build.(field, field_value(field, section, defaults), advanced?(field, defaults))
  end

  defp general_stream?(kind, preset), do: kind == "stream" and preset == nil

  # A row is under More options when the preset fills it, or fills another way
  # to settle what it is for: a preset that names the identity folds both
  # identity rows, and one that names the type folds the type header.
  defp advanced?(%{config: config}, _defaults) when config in @more_options, do: true

  defp advanced?(%{config: config}, defaults) when config in [:id_header, :id],
    do: Enum.any?(CuesConfig.identity_fields(), &Map.has_key?(defaults, &1))

  defp advanced?(%{config: :type_header}, defaults),
    do: Map.has_key?(defaults, :type_header) or Map.has_key?(defaults, :type_path)

  defp advanced?(field, defaults), do: Map.has_key?(defaults, field.config)

  defp field_value(field, section, defaults) do
    case Keyword.fetch(section, field.config) do
      {:ok, value} -> wire_value(field, value)
      :error -> wire_value(field, Map.get(defaults, field.config))
    end
  end

  defp wire_value(%{config: :interval}, seconds) when is_integer(seconds),
    do: if(rem(seconds, 60) == 0, do: div(seconds, 60), else: seconds / 60)

  defp wire_value(%{config: :id}, value), do: to_string(value) == "content_hash"
  defp wire_value(%{config: :daily_budget}, nil), do: 0
  defp wire_value(%{kind: :list}, nil), do: []
  defp wire_value(%{kind: :text}, nil), do: ""
  defp wire_value(%{kind: :choice}, nil), do: ""
  defp wire_value(_field, value) when is_atom(value) and not is_nil(value), do: to_string(value)
  defp wire_value(_field, value), do: value

  defp field_row(%{key: "url"}, value, advanced, preset) do
    Row.new("url", :text, url_label(preset),
      value: value,
      advanced: advanced,
      restart: restart()
    )
  end

  defp field_row(%{key: "handles"}, value, advanced, _preset) do
    Row.new("handles", :list, @handles_row.label,
      info: @handles_row.info,
      example: @handles_row.example,
      value: value,
      advanced: advanced,
      restart: restart()
    )
  end

  defp field_row(%{key: "interval_minutes"}, value, advanced, _preset) do
    Row.new("interval_minutes", :number, field_words("interval_minutes").label,
      value: value,
      min: 1,
      step: 1,
      unit: "minutes",
      format: :minutes,
      advanced: advanced,
      restart: restart()
    )
  end

  defp field_row(%{key: "verify"}, value, advanced, _preset) do
    Row.new("verify", :choice, field_words("verify").label,
      value: value,
      options: Enum.map(@verify_options, fn {id, label} -> Row.option(id, label) end),
      advanced: advanced,
      restart: restart()
    )
  end

  defp field_row(%{key: "algorithm"}, value, advanced, _preset) do
    Row.new("algorithm", :choice, field_words("algorithm").label,
      value: value,
      options: Enum.map(@algorithms, &Row.option(&1, String.upcase(&1))),
      advanced: advanced,
      restart: restart()
    )
  end

  defp field_row(%{key: "content_hash"}, value, advanced, _preset) do
    words = field_words("content_hash")

    Row.new("content_hash", :toggle, words.label,
      info: words.info,
      value: value,
      advanced: advanced,
      restart: restart()
    )
  end

  defp field_row(%{key: "daily_budget"}, value, advanced, _preset) do
    words = field_words("daily_budget")

    Row.new("daily_budget", :number, words.label,
      info: words.info,
      value: value,
      min: 0,
      step: 1,
      format: :integer,
      advanced: advanced,
      restart: restart()
    )
  end

  defp field_row(%{key: key}, value, advanced, _preset) do
    Row.new(key, :text, field_words(key).label,
      value: value,
      advanced: advanced,
      restart: restart()
    )
  end

  # A stream with no preset: every row but the budget with its label and an
  # info saying what it is for.
  defp general_row(%{key: "daily_budget"} = field, value, advanced),
    do: field_row(field, value, advanced, nil)

  defp general_row(%{key: key, kind: kind}, value, advanced) do
    {label, info, example} = Map.fetch!(@general_row_words, key)

    Row.new(key, kind, label,
      info: info,
      example: example,
      value: value,
      advanced: advanced,
      restart: restart()
    )
  end

  # The secrets a form takes, each row with its own field's presence in
  # `secrets` (a source's sentinels by field): a webhook's signing or shared
  # secret, and the key and secret a stream with no preset signs in with. A
  # local push's token is Fermix's to make, and a feed needs none.
  defp secret_rows("webhook", _preset, method, secrets),
    do: [secret_row(:secret, webhook_secret_label(method), secrets)]

  defp secret_rows("stream", nil, _method, secrets),
    do: [secret_row(:key, "API key", secrets), secret_row(:secret, "API secret", secrets)]

  defp secret_rows(_kind, _preset, _method, _secrets), do: []

  # A stream with no preset asks for its API key and secret straight after its
  # address, ahead of the fields that say how they are sent, so a value is not
  # typed where a header's name goes. Every other form ends with its secret.
  defp with_secrets(rows, secrets, kind, preset) do
    if general_stream?(kind, preset) do
      {head, rest} = Enum.split(rows, Enum.find_index(rows, &(&1["key"] == "url")) + 1)
      head ++ secrets ++ rest
    else
      rows ++ secrets
    end
  end

  defp secret_row(field, label, secrets) do
    Row.new(Atom.to_string(field), :secret, label,
      info: @secret_info,
      present: Map.has_key?(secrets, field),
      restart: restart()
    )
  end

  defp shown("feed", "x_accounts", _method), do: fields(~w(handles interval_minutes daily_budget))
  defp shown("feed", _preset, _method), do: fields(~w(url interval_minutes daily_budget))
  defp shown("stream", nil, _method), do: fields(@general_stream_keys)
  defp shown("local_push", _preset, _method), do: fields(~w(daily_budget))

  defp shown("webhook", _preset, method),
    do: fields(["verify" | method_keys(method)] ++ ~w(type_header daily_budget))

  defp method_keys("hmac"), do: ~w(header algorithm prefix id_header content_hash)
  defp method_keys("shared_secret"), do: ~w(header id_header content_hash)
  defp method_keys(_standard_or_none), do: []

  defp fields(keys), do: Enum.map(keys, &Map.fetch!(@field_by_key, &1))

  defp restart, do: Row.restart?([:cues, :sources])

  # --- values ------------------------------------------------------------------

  defp entries(values, kind, preset, method, defaults) do
    allowed = MapSet.new(shown(kind, preset, method), & &1.key)

    Enum.reduce_while(values, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case entry(key, value, allowed, defaults) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, refusal} -> {:halt, {:error, refusal}}
      end
    end)
    |> sort_entries()
  end

  defp entry(key, _value, _allowed, _defaults) when key in ["key", "secret"],
    do: {:error, {key, @secret_value}}

  defp entry(key, value, allowed, defaults) do
    case Map.fetch(@field_by_key, key) do
      {:ok, field} -> allowed_entry(field, value, MapSet.member?(allowed, key), defaults)
      :error -> {:error, {key, @unknown_field}}
    end
  end

  defp allowed_entry(field, _value, false, _defaults),
    do: {:error, {field.key, "This setting does not apply to this kind of source."}}

  defp allowed_entry(field, value, true, defaults) do
    with {:ok, coerced} <- coerce(field, value) do
      {:ok, default_or_value(field, coerced, defaults)}
    end
  end

  # A value equal to what the preset fills is left to the preset.
  defp default_or_value(field, coerced, defaults) do
    if Map.get(defaults, field.config) |> persisted() == coerced,
      do: {field.config, nil},
      else: {field.config, coerced}
  end

  defp persisted(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp persisted(value), do: value

  defp coerce(field, nil), do: {:error, {field.key, "This setting cannot be cleared."}}
  defp coerce(%{kind: :text} = field, value) when is_binary(value), do: line(field, value)

  defp coerce(%{kind: :choice} = field, value) when is_binary(value),
    do: choice(field, value)

  defp coerce(%{config: :interval}, value) when is_number(value) and value > 0,
    do: {:ok, round(value * 60)}

  defp coerce(%{config: :daily_budget}, value) when is_integer(value), do: {:ok, value}
  defp coerce(%{config: :id}, true), do: {:ok, "content_hash"}
  defp coerce(%{config: :id}, false), do: {:ok, ""}

  defp coerce(%{kind: :list} = field, values) when is_list(values) do
    cond do
      length(values) > @max_list_items ->
        {:error, {field.key, "This setting takes at most #{@max_list_items} values."}}

      Enum.all?(values, &is_binary/1) ->
        values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> listed(field)

      true ->
        {:error, {field.key, "This setting takes a list of text values."}}
    end
  end

  defp coerce(field, _value), do: {:error, {field.key, "This setting takes #{expected(field)}."}}

  # X accounts keeps its handles as X spells them in a search.
  defp listed(values, %{config: :handles} = field) do
    case XAccounts.handles(values) do
      {:ok, handles} -> {:ok, handles}
      {:error, words} -> {:error, {field.key, words}}
    end
  end

  defp listed(values, _field), do: {:ok, values}

  defp line(field, value) do
    line = String.trim(value)

    if String.match?(line, ~r/[\x00-\x1F\x7F]/),
      do: {:error, {field.key, @single_line}},
      else: {:ok, line}
  end

  defp choice(%{key: "verify"}, value) when value in @verify_ids, do: {:ok, value}
  defp choice(%{key: "algorithm"}, value) when value in @algorithms, do: {:ok, value}
  defp choice(field, _value), do: {:error, {field.key, @published_value}}

  defp expected(%{config: :interval}), do: "a number of minutes above 0"
  defp expected(%{config: :daily_budget}), do: "a whole number"
  defp expected(%{kind: :toggle}), do: "true or false"
  defp expected(%{kind: :list}), do: "a list of text values"
  defp expected(_field), do: "text"

  # Form order, whatever order the values arrived in.
  defp sort_entries({:ok, entries}) do
    order = @fields |> Enum.map(& &1.config) |> Enum.with_index() |> Map.new()
    {:ok, Enum.sort_by(entries, fn {config, _value} -> Map.fetch!(order, config) end)}
  end

  defp sort_entries(refusal), do: refusal

  defp blank_entry?({_config, value}), do: value in [nil, "", []]

  defp apply_entry({config, value}, section) do
    if value in [nil, "", []],
      do: Keyword.delete(section, config),
      else: put_key(section, config, value)
  end

  # Replaces a key where it stands, so a save keeps the file's order.
  defp put_key(keyword, key, value) do
    if Keyword.has_key?(keyword, key),
      do: List.keyreplace(keyword, key, 0, {key, value}),
      else: keyword ++ [{key, value}]
  end

  defp text(nil), do: nil
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value
end
