defmodule FermixCore.Cues.XAccounts do
  @moduledoc """
  The X accounts source (M60_X_ACCOUNTS_SOURCE.md): a feed whose preset,
  `x_accounts`, asks X's recent search for the new posts of the handles the
  source names, signed in with the X plugin's own sign-in. The source stores
  no secret and no address.

  This module owns what is X's: the handle rule, the search address, the
  cursor, the reading of X's answer into cue item fields, X's refusal for the
  log, and where the sign-in comes from. `Cues.Source.Feed` polls, pins,
  backs off and accepts as it does for any feed.

  **Search.** One request per poll for every handle:
  `(from:a OR from:b) -is:retweet` (reposts are other people's posts; replies
  and quotes are the account's own words), at most 100 posts, each with its
  author joined from `includes.users`.

  **Cursor** (`cue_sources.cursor`, JSON): `start_time`, the moment watching
  began, and `since_id`, the newest post seen (X's `meta.newest_id`). A poll
  sends `since_id` once there is one, else `start_time`, never both. X's
  recent search reaches back 7 days and refuses a bound older than that, so a
  bound past the window goes out as 7 days ago less a minute; the posts before
  it are left out the way a feed leaves out items past the receipt horizon. X's
  search ends 30 seconds before each request and refuses a start after its end,
  so a start that recent goes out a minute before the request.

  **Text.** X cuts a post's `text` at 280 characters and sends a long post's
  whole text in `note_tweet`, so an item's `text` is the post's whole text:
  `note_tweet.text` when X sends one, which replaces the cut `text` and is not
  kept beside it.

  Pure but `sign_in_token/1`, `sign_in_refresh/1` and `sign_in_state/1`,
  which read the plugin registry and ask `Auth.TokenManager`.
  """

  alias FermixCore.Auth.TokenManager
  alias FermixCore.Cues.JsonPath
  alias FermixCore.Plugins.Config, as: PluginConfig
  alias FermixCore.Plugins.Registry

  @preset "x_accounts"
  @plugin "x"
  @search_url "https://api.x.com/2/tweets/search/recent"
  @handle ~r/\A[A-Za-z0-9_]{1,15}\z/
  @max_handles 20
  # X's limit on a query for pay-per-use access.
  @max_query_chars 512
  @window_s 7 * 86_400
  @window_margin_s 60
  @search_lag_s 60
  @post_id ~r/\A[0-9]{1,20}\z/
  # X's ids carry the milliseconds since this epoch in their bits above 22.
  @id_epoch_ms 1_288_834_974_657
  @item_type "x.post"
  @paths %{id_path: "id", time_path: "created_at", subject_path: "author_id"}
  @max_problem_bytes 65_536
  @max_problem_chars 300

  @typedoc "The cursor as the worker keeps it: JSON's own shape, string keys."
  @type cursor :: %{optional(String.t()) => String.t()}

  @doc "The preset's name."
  @spec preset() :: String.t()
  def preset, do: @preset

  @doc """
  `typed` as the source keeps it: each handle without a leading `@`,
  lowercased, once. Refused with a sentence for the owner when one is not an
  X username (`[A-Za-z0-9_]{1,15}`), when there are more than 20, or when the
  search they make would pass X's 512 characters. An empty list is no
  refusal here: the presence rule (`Cues.Config.required_fields/3`) says so.
  """
  @spec handles(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def handles(typed) when is_list(typed) do
    with {:ok, handles} <- each_handle(typed),
         handles = Enum.uniq(handles),
         :ok <- at_most(handles) do
      fits(handles)
    end
  end

  def handles(_typed), do: {:error, "Handles are a list of X usernames."}

  defp each_handle(typed) do
    Enum.reduce_while(typed, {:ok, []}, fn entry, {:ok, acc} ->
      case handle(entry) do
        {:ok, handle} -> {:cont, {:ok, acc ++ [handle]}}
        {:error, words} -> {:halt, {:error, words}}
      end
    end)
  end

  defp handle(entry) when is_binary(entry) do
    name = entry |> String.trim() |> String.trim_leading("@")

    if Regex.match?(@handle, name),
      do: {:ok, String.downcase(name)},
      else: {:error, "#{inspect(entry)} is not an X username: #{username_rule()}"}
  end

  defp handle(entry), do: {:error, "#{inspect(entry)} is not an X username: #{username_rule()}"}

  defp username_rule, do: "letters, digits and underscores, at most 15 of them."

  defp at_most(handles) when length(handles) <= @max_handles, do: :ok

  defp at_most(handles),
    do: {:error, "X accounts watches at most #{@max_handles} handles, not #{length(handles)}."}

  defp fits([]), do: {:ok, []}

  defp fits(handles) do
    if String.length(query(handles)) <= @max_query_chars,
      do: {:ok, handles},
      else:
        {:error, "These handles make a search longer than X's #{@max_query_chars} characters."}
  end

  @doc "The search for `handles`' own posts, reposts left out."
  @spec query([String.t()]) :: String.t()
  def query([_first | _rest] = handles),
    do: "(" <> Enum.map_join(handles, " OR ", &("from:" <> &1)) <> ") -is:retweet"

  @doc """
  `cursor` (a feed cursor as decoded, string keys) as an X cursor: its
  `since_id` and `start_time` where they are X's, with watching starting at
  `now` when it has no start. Anything else in it is dropped.
  """
  @spec start_watching(map(), DateTime.t()) :: cursor()
  def start_watching(cursor, %DateTime{} = now) when is_map(cursor) do
    start = parsed_time(Map.get(cursor, "start_time")) || now
    since_id = Map.get(cursor, "since_id")
    base = %{"start_time" => stamp(start)}

    if post_id?(since_id), do: Map.put(base, "since_id", since_id), else: base
  end

  @doc "The search address of one poll at `now`, for an X cursor (`start_watching/2`)."
  @spec search_url([String.t()], cursor(), DateTime.t()) :: String.t()
  def search_url(handles, %{"start_time" => _start} = cursor, %DateTime{} = now)
      when is_list(handles) do
    params = [
      {"query", query(handles)},
      {"tweet.fields", "created_at,author_id,note_tweet"},
      {"expansions", "author_id"},
      {"user.fields", "username,name"},
      {"max_results", "100"},
      bound(cursor, now)
    ]

    @search_url <> "?" <> URI.encode_query(params, :rfc3986)
  end

  # `since_id` while its post is inside X's window, else `start_time` held
  # inside the window and at least a minute before the request.
  defp bound(cursor, now) do
    floor = DateTime.add(now, @window_margin_s - @window_s, :second)
    since_id = Map.get(cursor, "since_id")

    if since_id && DateTime.compare(posted_at(since_id), floor) != :lt,
      do: {"since_id", since_id},
      else: {"start_time", cursor |> start_time() |> within(floor, now) |> stamp()}
  end

  defp start_time(cursor), do: cursor |> Map.fetch!("start_time") |> parsed_time()

  defp within(start, floor, now) do
    latest = DateTime.add(now, -@search_lag_s, :second)
    [start, latest] |> Enum.min(DateTime) |> then(&Enum.max([&1, floor], DateTime))
  end

  defp posted_at(id) do
    ms = Bitwise.bsr(String.to_integer(id), 22) + @id_epoch_ms
    DateTime.from_unix!(ms, :millisecond)
  end

  @doc "The headers that carry the X sign-in."
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(token) when is_binary(token) and token != "",
    do: [{"accept", "application/json"}, {"authorization", "Bearer " <> token}]

  @doc """
  X's answer (the decoded document) as cue item fields, the next cursor as
  JSON and what the poll left out. Each post is one item: identity `id`, time
  `created_at`, subject `author_id`, type `x.post`, its data the post with
  `author` (`id`, `username`, `name`, from `includes.users`) and `url`. The
  next `since_id` is `meta.newest_id`; an answer with no posts keeps the
  cursor. X's `meta.next_token` says posts were left out past the first 100:
  one `page_limit` gap that ends at the oldest post read (X says only that
  some are left). An answer not in X's shape is refused.
  """
  @spec read(term(), cursor()) ::
          {:ok, [map()], String.t(), FermixCore.Cues.FeedParser.outcome()}
          | {:error, {:invalid_x_response, atom()}}
  def read(%{} = document, cursor) when is_map(cursor) do
    with {:ok, posts} <- posts(document),
         {:ok, authors} <- authors(document),
         {:ok, meta} <- meta(document),
         {:ok, cursor} <- advance(cursor, posts, meta) do
      fields = Enum.map(posts, &post_fields(&1, authors))
      {:ok, fields, Jason.encode!(cursor), %{truncation: truncation(meta, fields), skipped: 0}}
    end
  end

  def read(_document, _cursor), do: {:error, {:invalid_x_response, :document}}

  # X leaves `data` out when nothing matched.
  defp posts(%{"data" => posts}) when is_list(posts) do
    if Enum.all?(posts, &(is_map(&1) and post_id?(&1["id"]))),
      do: {:ok, posts},
      else: {:error, {:invalid_x_response, :data}}
  end

  defp posts(%{"data" => _other}), do: {:error, {:invalid_x_response, :data}}
  defp posts(_document), do: {:ok, []}

  defp authors(%{"includes" => %{"users" => users}}) when is_list(users) do
    if Enum.all?(users, &(is_map(&1) and is_binary(&1["id"]))),
      do: {:ok, Map.new(users, &{&1["id"], Map.take(&1, ["id", "username", "name"])})},
      else: {:error, {:invalid_x_response, :includes}}
  end

  defp authors(%{"includes" => %{"users" => _other}}),
    do: {:error, {:invalid_x_response, :includes}}

  defp authors(_document), do: {:ok, %{}}

  defp meta(%{"meta" => %{} = meta}), do: {:ok, meta}
  defp meta(_document), do: {:error, {:invalid_x_response, :meta}}

  defp advance(cursor, [], _meta), do: {:ok, cursor}

  defp advance(cursor, _posts, %{"newest_id" => newest}) do
    if post_id?(newest),
      do: {:ok, Map.put(cursor, "since_id", newest)},
      else: {:error, {:invalid_x_response, :meta}}
  end

  defp advance(_cursor, _posts, _meta), do: {:error, {:invalid_x_response, :meta}}

  defp post_fields(post, authors) do
    author = Map.get(authors, post["author_id"])

    post
    |> whole_text()
    |> put_author(author)
    |> Map.put("url", post_url(post["id"], author))
    |> JsonPath.fields(@paths, @item_type)
  end

  defp whole_text(%{"note_tweet" => %{"text" => text}} = post) when is_binary(text),
    do: post |> Map.delete("note_tweet") |> Map.put("text", text)

  defp whole_text(post), do: post

  defp put_author(post, nil), do: post
  defp put_author(post, author), do: Map.put(post, "author", author)

  # A username X sends is one; anything else links the post by its id alone.
  defp post_url(id, %{"username" => name}) when is_binary(name) do
    if Regex.match?(@handle, name),
      do: "https://x.com/#{name}/status/#{id}",
      else: "https://x.com/i/status/#{id}"
  end

  defp post_url(id, _author), do: "https://x.com/i/status/#{id}"

  defp truncation(%{"next_token" => token}, fields) when is_binary(token) do
    oldest = fields |> Enum.map(& &1.occurred_at) |> Enum.reject(&is_nil/1) |> earliest()
    {:truncated, %{count: 1, range_from: nil, range_to: oldest}}
  end

  defp truncation(_meta, _fields), do: :complete

  defp earliest([]), do: nil
  defp earliest(times), do: Enum.min(times, DateTime)

  @doc """
  An answer of HTTP `status` as a failure reason: X's own `title` and
  `detail` from `body`, each cut to 300 characters, for the log. Nothing of it
  reaches a notice or the source's row.
  """
  @spec refusal(pos_integer(), binary()) :: {:http_status, pos_integer(), map()}
  def refusal(status, body) when is_integer(status) and is_binary(body),
    do: {:http_status, status, problem(body)}

  defp problem(body) when byte_size(body) > @max_problem_bytes, do: %{}

  defp problem(body) do
    case Jason.decode(body) do
      {:ok, %{} = problem} ->
        for key <- ["title", "detail"],
            value = problem[key],
            is_binary(value),
            into: %{},
            do: {key, String.slice(value, 0, @max_problem_chars)}

      _not_a_problem ->
        %{}
    end
  end

  @doc """
  The access token of the X plugin's sign-in: the installed plugin named `x`,
  switched on, its auth profile's token from `Auth.TokenManager` (which
  refreshes it). A token server that does not answer, or crashes, exits the
  call; that is `{:error, {:token_server_unavailable, kind}}`, never an exit.
  `opts` are seams for a test: `:find` (default `Plugins.Registry.find/1`),
  `:enabled` (default `Plugins.Config.enabled_plugins/0`) and `:get_token`
  (default `Auth.TokenManager.get_token/1`).
  """
  @spec sign_in_token(keyword()) :: {:ok, String.t()} | {:error, term()}
  def sign_in_token(opts \\ []) when is_list(opts),
    do: profile_call(opts, Keyword.get(opts, :get_token, &TokenManager.get_token/1))

  @doc """
  A new access token for the X plugin's sign-in, after X refused the one it
  had: `sign_in_token/1`'s rules, with `:refresh` (default
  `Auth.TokenManager.refresh/1`) in place of `:get_token`.
  """
  @spec sign_in_refresh(keyword()) :: {:ok, String.t()} | {:error, term()}
  def sign_in_refresh(opts \\ []) when is_list(opts),
    do: profile_call(opts, Keyword.get(opts, :refresh, &TokenManager.refresh/1))

  @doc """
  Whether the X plugin's sign-in is there for this source to read with, as
  the add form says it: `sign_in_token/1`'s plugin, switch and auth profile,
  asking `Auth.TokenManager.status/1` instead of for the token, so asking
  never refreshes it. `:ready` when a token is loaded and X has not refused
  it; else the reason, which is always a sign-in to make (`:no_token`,
  `:sign_in_refused`, or one `sign_in_token/1` names). Seams: `:find`,
  `:enabled` and `:status` (default `Auth.TokenManager.status/1`).
  """
  @spec sign_in_state(keyword()) :: :ready | {:error, term()}
  def sign_in_state(opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status, &TokenManager.status/1)

    with {:ok, profile} <- sign_in_profile(opts) do
      status_call(fn -> status.(profile) end)
    end
  end

  defp profile_call(opts, call) do
    with {:ok, profile} <- sign_in_profile(opts) do
      token_call(fn -> call.(profile) end)
    end
  end

  defp sign_in_profile(opts) do
    find = Keyword.get(opts, :find, &Registry.find/1)
    enabled = Keyword.get(opts, :enabled, &PluginConfig.enabled_plugins/0)

    with {:ok, plugin} <- installed(find.(@plugin)),
         :ok <- switched_on(plugin, enabled.()) do
      {:ok, PluginConfig.auth_profile(plugin)}
    end
  end

  defp installed({:ok, plugin}), do: {:ok, plugin}
  defp installed(:error), do: {:error, :x_plugin_not_installed}
  defp installed({:error, reason}), do: {:error, reason}

  defp switched_on(plugin, enabled) do
    if plugin.name in enabled, do: :ok, else: {:error, :x_plugin_off}
  end

  # A wedged or crashed token server exits the GenServer call; that is a
  # missing sign-in, so a source waits for one instead of crashing.
  defp token_call(call) do
    case call.() do
      {:ok, token} when is_binary(token) and token != "" -> {:ok, token}
      {:ok, _empty} -> {:error, :empty_token}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:token_server_unavailable, exit_kind(reason)}}
  end

  defp status_call(call) do
    loaded(call.())
  catch
    :exit, reason -> {:error, {:token_server_unavailable, exit_kind(reason)}}
  end

  defp loaded({:ok, %{loaded?: true, invalidated?: true}}), do: {:error, :sign_in_refused}
  defp loaded({:ok, %{loaded?: true}}), do: :ready
  defp loaded({:ok, %{loaded?: false}}), do: {:error, :no_token}
  defp loaded({:error, reason}), do: {:error, reason}

  defp exit_kind({kind, _call}) when is_atom(kind), do: kind
  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_reason), do: :exit

  # --- small helpers -------------------------------------------------------------

  defp post_id?(id), do: is_binary(id) and Regex.match?(@post_id, id)

  defp parsed_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp parsed_time(_other), do: nil

  # Second precision, as X takes it: `2026-10-10T12:00:00Z`.
  defp stamp(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
