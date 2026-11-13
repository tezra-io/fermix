defmodule FermixCore.Computers.Capabilities.Notifications do
  @moduledoc """
  `notifications` (M99 §10.1): a notification this computer's server asks it
  to show, posted the same local way a home on this computer posts one,
  through this engine's own `FermixCore.Native.Notifications` (the Fermix
  app's native host on a Mac, the session bus on Linux). It has no offer of
  its own (M97 D27): the master switch alone gates it.

  - `post` shows one notification: `key` (1 to 128 letters, digits and
    `._:-`, starting with a letter or a digit: the reminder's own key),
    `title` (1 to #{256} characters), `body` (at most #{1_800}), `sound`,
    and `reminder_id` (1 to #{64} characters) for a
    reminder, which the Mac app offers Snooze 10 minutes on; no other key. It
    answers `{"shown": "now"}`, or `{"shown": "before"}` for a key it already
    showed, or fails with the backend's `reason` (`Native.Notifications`'
    closed set: `not_authorized`, `no_server`, `host_unavailable`, `timeout`,
    `backend_missing`, `not_offered` or `failed`) and its words.
  - `ready` takes nothing and answers `{"ready": true}`, or `{"ready":
    false, "sentence": …}` in the backend's own clause, at most #{300}
    bytes. It asks with no turn's context, so it never raises a permission
    prompt on the computer.

  **Once per key.** A key is claimed in the table `Desktop.Invoke` owns
  (`context.notifications.shown`, so it outlives a restart of Admission)
  before the post: a post that shows keeps its claim, one that fails lets it
  go, so the server's next retry posts again, and a key already claimed shows
  nothing. A run that ends without answering (stopped past its deadline)
  keeps its claim: whether it showed is not known, and it never shows twice.
  At most #{512} keys are kept, each for a day, the expired ones dropped
  first, then the oldest; the table lives in memory, so an engine restart
  between a lost answer and the retry can show one twice.

  The context's `notifications.native` are `Native.Notifications`' options
  (a test's backend seams; none in production, where this engine's role
  places the post here).
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.Native.Notifications
  alias FermixCore.NativeHost.Protocol

  @key ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
  @post_keys ["body", "key", "reminder_id", "sound", "title"]
  @required_keys ["body", "key", "sound", "title"]
  @max_reminder_id_chars 64
  @max_sentence_bytes 300
  @max_keys 512
  @kept_ms 24 * 60 * 60_000

  @impl true
  def id, do: :notifications

  @impl true
  def offer, do: nil

  @impl true
  def ops, do: ["post", "ready"]

  @impl true
  def label, do: "notifications"

  @impl true
  def op_label("post"), do: "show a notification"
  def op_label("ready"), do: "check notifications"

  @impl true
  def effect?("post"), do: true
  def effect?("ready"), do: false

  @impl true
  def long_lived?(op) when op in ["post", "ready"], do: false

  @impl true
  def deadline_ms("post", _args), do: 15_000
  def deadline_ms("ready", _args), do: 10_000

  @impl true
  def bounds(op) when op in ["post", "ready"], do: %{result_bytes: 1_024, part_bytes: 0}

  @impl true
  def admit(op, _args, _context) when op in ["post", "ready"], do: :ok

  # A readiness check is no thing Fermix did on this computer.
  @impl true
  def recorded?("ready", _args), do: false
  def recorded?("post", _args), do: true

  @impl true
  def target("post", %{"reminder_id" => id}) when is_binary(id), do: "reminder " <> id
  def target(_op, _args), do: "notification"

  @impl true
  def validate("ready", args) when map_size(args) == 0, do: :ok
  def validate("ready", _args), do: {:error, "Checking notifications takes no arguments."}

  def validate("post", args) when is_map(args) do
    keys = Map.keys(args)

    if keys -- @post_keys == [] and @required_keys -- keys == [],
      do: first_refusal(args),
      else:
        {:error, "A notification takes key, title, body and sound, and optionally reminder_id."}
  end

  # The first argument outside its bounds, in the order the moduledoc names them.
  defp first_refusal(args) do
    Enum.find_value(post_checks(), :ok, fn {holds?, sentence} ->
      if holds?.(args), do: nil, else: {:error, sentence}
    end)
  end

  defp post_checks do
    [
      {&key?(&1["key"]),
       "A notification's key is 1 to 128 letters, digits and . _ : -, starting with a letter " <>
         "or a digit."},
      {&text?(&1["title"], 1, Protocol.max_title_chars()),
       "A notification's title is 1 to #{Protocol.max_title_chars()} characters."},
      {&text?(&1["body"], 0, Protocol.max_body_chars()),
       "A notification's body is at most #{Protocol.max_body_chars()} characters."},
      {&is_boolean(&1["sound"]), "A notification's sound is true or false."},
      {&reminder_id?/1,
       "A notification's reminder_id is 1 to #{@max_reminder_id_chars} characters."}
    ]
  end

  defp key?(key), do: is_binary(key) and Regex.match?(@key, key)

  @impl true
  def run(_op, _args, part, _context) when is_binary(part),
    do: {:failed, "A notification carries no file."}

  def run("post", args, nil, %{notifications: %{shown: shown, native: native}} = context),
    do: post_once(args, shown, native, DateTime.to_unix(context.clock.(), :millisecond))

  def run("ready", _args, nil, %{notifications: %{native: native}}), do: ready(native)

  # -- once per key ------------------------------------------------------------------

  defp post_once(%{"key" => key} = args, shown, native, now_ms) do
    :ok = forget_expired(shown, now_ms)

    if :ets.member(shown, key),
      do: {:ok, %{"shown" => "before"}, nil},
      else: claim(args, shown, native, now_ms)
  end

  # A claim made beside this one (two asks of one key at once) wins, and this
  # one shows nothing.
  defp claim(%{"key" => key} = args, shown, native, now_ms) do
    :ok = make_room(shown)

    if :ets.insert_new(shown, {key, now_ms}),
      do: posted(args, shown, native),
      else: {:ok, %{"shown" => "before"}, nil}
  end

  defp posted(%{"key" => key} = args, shown, native) do
    case Notifications.post(notification(args), native) do
      {:ok, _id} ->
        {:ok, %{"shown" => "now"}, nil}

      {:error, reason} ->
        true = :ets.delete(shown, key)
        {:failed, words(reason), %{"reason" => word(reason)}, nil}
    end
  end

  defp notification(args) do
    %{
      title: args["title"],
      body: args["body"],
      sound: args["sound"],
      reminder_id: Map.get(args, "reminder_id")
    }
  end

  # A key is kept a day.
  defp forget_expired(shown, now_ms) do
    cutoff = now_ms - @kept_ms
    _expired = :ets.select_delete(shown, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
    :ok
  end

  # The oldest go until one more fits: the table holds at most 512 keys, so
  # each pass reads at most that many rows.
  defp make_room(shown), do: forget_oldest(shown, :ets.info(shown, :size) - (@max_keys - 1))

  defp forget_oldest(_shown, over) when over <= 0, do: :ok

  defp forget_oldest(shown, over) do
    shown
    |> :ets.tab2list()
    |> Enum.sort_by(fn {_key, at_ms} -> at_ms end)
    |> Enum.take(over)
    |> Enum.each(fn {key, _at_ms} -> true = :ets.delete(shown, key) end)
  end

  # -- ready ---------------------------------------------------------------------------

  # No turn's context: the computer is asked by its server, never by the
  # person at it, so no permission prompt is raised here.
  defp ready(native) do
    case Notifications.ready(%{}, native) do
      :ok -> {:ok, %{"ready" => true}, nil}
      {:error, sentence} -> {:ok, %{"ready" => false, "sentence" => clip(sentence)}, nil}
    end
  end

  defp clip(text) when byte_size(text) <= @max_sentence_bytes, do: text

  defp clip(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      if byte_size(acc) + byte_size(grapheme) <= @max_sentence_bytes,
        do: {:cont, acc <> grapheme},
        else: {:halt, acc}
    end)
  end

  # -- words ---------------------------------------------------------------------------

  defp word(:not_authorized), do: "not_authorized"
  defp word(:no_server), do: "no_server"
  defp word(:host_unavailable), do: "host_unavailable"
  defp word(:timeout), do: "timeout"
  defp word(:backend_missing), do: "backend_missing"
  defp word(:not_offered), do: "not_offered"
  defp word({:failed, _evidence}), do: "failed"

  defp words(:not_authorized), do: "Fermix is not allowed to show notifications on this computer."
  defp words(:no_server), do: "No desktop notification server is running on this computer."
  defp words(:host_unavailable), do: "The Fermix app on this computer could not be reached."
  defp words(:timeout), do: "The notification did not show in time."
  defp words(:backend_missing), do: "This computer has no busctl to reach its session bus."
  defp words(:not_offered), do: "Fermix on this computer shows no notifications."
  defp words({:failed, evidence}) when is_binary(evidence), do: evidence

  defp text?(value, min, max) when is_binary(value),
    do: String.valid?(value) and scalars(value) in min..max

  defp text?(_value, _min, _max), do: false

  defp reminder_id?(%{"reminder_id" => id}), do: text?(id, 1, @max_reminder_id_chars)
  defp reminder_id?(_args), do: true

  defp scalars(text), do: text |> String.to_charlist() |> length()
end
