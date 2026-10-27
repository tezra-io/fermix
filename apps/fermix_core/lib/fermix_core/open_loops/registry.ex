defmodule FermixCore.OpenLoops.Registry do
  @moduledoc """
  Validation and orchestration for open loops (MILESTONE_78 §04, §07, §18).

  The only layer that turns the model's arguments into a stored loop or a
  settled one. It owns:

    * **the gate** — `OpenLoops.Access`: noting and settling need the owner's
      attended turn in a private chat, outside a check-in; listing also admits
      a check-in run;
    * **provenance** — a loop noted on a turn that had read outside content
      (`OpenLoops.Access.read_outside?/1`) is stamped
      `noted_after_outside_content`, so its words are framed wherever they come
      back; on such a turn an answer's `owner_words` must be the owner's own,
      found in what they typed (`:owner_text`);
    * **the clock and the zone** — the tagged date form is resolved as
      `Temporal.Registry` resolves an event's `when`, in the owner-named zone or
      `[fermix_core.personalization] timezone`; a loop is dated, so the timer
      and yearly forms are refused;
    * **the dedupe key** — the intention lowercased, punctuation stripped,
      whitespace collapsed and bounded, never model-authored;
    * **the delivery snapshot** — the owner inbox ladder
      (`Delivery.OwnerInbox.resolve/1`) resolved once at capture; no inbox, or
      only this computer's notifications, is no target, because a check-in
      needs somewhere to be answered;
    * **the post-commit scheduler signal** — a cast of `:loop_changed` to the
      scheduler `opts[:scheduler]` names, never a compile dependency on it.

  `Memory.Repo` owns every transaction; this module never opens one.

  Seams (`opts`): `:repo` (the Repo server), `:now`, `:personalization`,
  `:jobs_config`, `:configured_owners` (the owner inbox's own seam) and
  `:scheduler` (nil: no signal).
  """

  require Logger

  alias FermixCore.Capabilities.UntrustedContent
  alias FermixCore.Clock
  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Memory.Repo
  alias FermixCore.Native.Notifications
  alias FermixCore.OpenLoops.Access
  alias FermixCore.OpenLoops.ActiveHours
  alias FermixCore.OpenLoops.Defaults
  alias FermixCore.OpenLoops.Lifecycle
  alias FermixCore.OpenLoops.Telemetry
  alias FermixCore.Temporal.Planner

  @notification_platform Notifications.platform()
  @note_keys [:intention, :why_it_matters, :matters_by, :timezone]
  @answers ~w(done plan not_yet stop drop asked)
  @list_states ~w(live closed any)
  @live ~w(open due asked)
  @relative_units %{"days" => 1, "weeks" => 7}
  @clock_units ~w(minutes hours)
  @max_relative_days 3_650
  @day_start ~T[00:00:00]
  @utc "Etc/UTC"

  @type note_result :: %{
          status: :created | :existing,
          loop: Repo.open_loop_row(),
          stated_as: String.t(),
          first_check: String.t(),
          delivery: %{platform: String.t(), source: atom() | nil},
          live_loops: non_neg_integer()
        }

  @type update_result :: %{
          loop: Repo.open_loop_row(),
          previous_state: String.t(),
          next_check: String.t() | nil
        }

  # --- note ------------------------------------------------------------------

  @doc """
  Records the owner's stated intention with the date by which it matters.

  `params` carries `intention`, `matters_by` (the tagged date form), and
  optionally `why_it_matters` and `timezone`, atom- or string-keyed. The same
  intention on a live loop returns that loop as stored (`status: :existing`)
  and writes nothing. `stated_as` is the date stated absolutely with its
  weekday, `first_check` the first slot in the loop's zone, `delivery` the
  snapshotted platform and how it was resolved (nil for an existing loop), and
  `live_loops` the owner's count after this call.
  """
  @spec note(map(), map(), keyword()) :: {:ok, note_result()} | {:error, term()}
  def note(params, context, opts \\ [])
      when is_map(params) and is_map(context) and is_list(opts) do
    now = now(opts)

    with :ok <- mutation_gate(context),
         {:ok, source} <- source(context),
         {:ok, spec} <- capture_spec(take(params, @note_keys), now, opts),
         {:ok, target} <- delivery_target(opts),
         {:ok, hours} <-
           active_hours(agent_id(context), owner_id(context), spec.timezone, now, opts),
         {:ok, attrs} <- capture_attrs(spec, source, target, context, {hours, now}),
         {:ok, {status, loop}} <- Repo.create_open_loop(attrs, repo_opts(opts)),
         {:ok, live} <- Repo.count_live_open_loops(loop.owner_id, repo_opts(opts)) do
      if status == :created, do: notify(opts)
      {:ok, note_result(status, loop, target, live, opts)}
    end
  end

  defp note_result(status, loop, target, live, opts) do
    %{
      status: status,
      loop: loop,
      stated_as: stated_matters_by(loop, opts),
      first_check: Clock.stated_instant(loop.next_touch_at, opts),
      delivery: %{platform: loop.delivery_platform, source: delivery_source(status, target)},
      live_loops: live
    }
  end

  defp delivery_source(:created, target), do: target.source
  defp delivery_source(:existing, _target), do: nil

  defp capture_spec(params, now, opts) do
    with :ok <- required_present(params, [:intention, :matters_by]),
         {:ok, intention} <- bounded_text(params.intention, :intention, Defaults.intention_max()),
         {:ok, dedupe_key} <- dedupe_key(intention),
         {:ok, why} <- optional_text(params.why_it_matters, :why_it_matters),
         {:ok, zone} <- resolve_timezone(params.timezone, opts),
         {:ok, date} <- resolve_date(params.matters_by, zone, now),
         :ok <- still_ahead(date.at, now) do
      {:ok,
       Map.merge(date, %{
         intention: intention,
         dedupe_key: dedupe_key,
         why_it_matters: why,
         timezone: zone,
         horizon_class: Defaults.horizon_class(now, date.at, zone)
       })}
    end
  end

  defp capture_attrs(spec, {channel, chat_id, scope}, target, context, {hours, now}) do
    loop = %{
      horizon_class: spec.horizon_class,
      matters_by_date: spec.date,
      matters_by_at: spec.at,
      timezone: spec.timezone
    }

    with {:ok, first} <- Lifecycle.first_touch_at(loop, hours, now) do
      {:ok,
       Map.merge(loop, %{
         id: new_id(),
         agent_id: agent_id(context),
         owner_id: owner_id(context),
         dedupe_key: spec.dedupe_key,
         intention: spec.intention,
         noted_after_outside_content: Access.read_outside?(context),
         why_it_matters: spec.why_it_matters,
         matters_by_kind: spec.kind,
         matters_by_time: spec.time,
         said_at: now,
         source_channel: channel,
         source_chat_id: chat_id,
         source_thread_scope: scope,
         next_touch_at: first,
         delivery_platform: target.platform,
         delivery_destination: target.destination,
         delivery_thread_scope: target.thread_scope,
         created_at: now
       })}
    end
  end

  defp new_id, do: "loop_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

  defp still_ahead(at, now) do
    if DateTime.compare(at, now) == :gt, do: :ok, else: {:error, :date_passed}
  end

  # --- update ----------------------------------------------------------------

  @doc """
  Settles or moves a loop from the owner's answer: `done`, `plan`, `not_yet`,
  `stop`, `drop` or `asked` (`OpenLoops.Lifecycle.after_answer/5`).

  `owner_words` is required for every answer but `asked`, at most 240
  characters, and never stored. On a turn that read outside content it must
  also appear, normalised as the dedupe key is, in the owner's own text for the
  turn (`:owner_text` of `context`: the message as typed, empty when it was
  forwarded): content the turn read could otherwise close, stop or move a loop
  under words the owner never said. A voice call's turn cannot be checked (a
  realtime call carries no `:owner_text`, and a hand-off's text is the
  exchange its session put together), nor can any context with no
  `:owner_text`, so such an answer is refused there, and the loop waits for the
  owner's chat.

  `plan_at` (the tagged date form, in the loop's zone; a date-only plan arms
  that day's active-hours start) goes with `plan` only. Traces
  `[:fermix, :open_loop, :settled]` with `by: "main_agent"`. `next_check` is
  stated after `plan` and `not_yet`.
  """
  @spec update(String.t(), map(), map(), keyword()) :: {:ok, update_result()} | {:error, term()}
  def update(id, params, context, opts \\ [])
      when is_binary(id) and is_map(params) and is_map(context) and is_list(opts) do
    now = now(opts)
    params = take(params, [:answer, :owner_words, :plan_at])

    with :ok <- mutation_gate(context),
         {:ok, answer} <- answer(params.answer),
         :ok <- owner_words(answer, params.owner_words),
         :ok <- owners_own_words(answer, params.owner_words, context),
         {:ok, loop} <- owned_loop(id, context, opts),
         :ok <- live(loop),
         {:ok, hours} <- active_hours(loop.agent_id, loop.owner_id, loop.timezone, now, opts),
         {:ok, plan_at} <- plan_at(params.plan_at, loop, hours, now),
         {:ok, changes} <- Lifecycle.after_answer(loop, answer, plan_at, now, hours),
         {:ok, settled} <- Repo.settle_open_loop(loop.id, changes, repo_opts(opts, now)) do
      Telemetry.settled(
        loop.id,
        loop.state,
        settled.state,
        answer,
        "main_agent",
        session_id(context)
      )

      notify(opts)

      {:ok,
       %{
         loop: settled,
         previous_state: loop.state,
         next_check: next_check(answer, settled, opts)
       }}
    end
  end

  defp answer(answer) when answer in @answers, do: {:ok, answer}
  defp answer(nil), do: {:error, {:missing_parameters, [:answer]}}
  defp answer(other), do: {:error, {:invalid_answer, other}}

  # A control argument, as `event_update`'s owner_direction is: validated for
  # presence and length, never merged and never stored. Its content is read
  # only after outside content, by `owners_own_words/3`.
  defp owner_words("asked", nil), do: :ok

  defp owner_words(answer, words) when is_binary(words) do
    cond do
      String.trim(words) == "" -> owner_words(answer, nil)
      String.length(words) > Defaults.owner_words_max() -> {:error, :owner_words_too_long}
      true -> :ok
    end
  end

  defp owner_words("asked", _words), do: {:error, {:invalid_param, :owner_words}}
  defp owner_words(_answer, nil), do: {:error, :missing_owner_words}
  defp owner_words(_answer, _words), do: {:error, {:invalid_param, :owner_words}}

  # After outside content the words must be found in what the owner typed, as
  # whole words once both are normalised; `asked` names no words, and a turn
  # that read nothing is taken at its word, as before. A voice call types
  # nothing, so its answer waits for the chat rather than for words that can
  # never come.
  defp owners_own_words("asked", _words, _context), do: :ok

  defp owners_own_words(_answer, words, context) do
    cond do
      not Access.read_outside?(context) -> :ok
      Access.voice_call?(context) -> {:error, :owner_words_unverifiable}
      not Map.has_key?(context, :owner_text) -> {:error, :owner_words_unverifiable}
      typed?(words, Map.fetch!(context, :owner_text)) -> :ok
      true -> {:error, :owner_words_not_in_message}
    end
  end

  defp typed?(words, owner_text) when is_binary(owner_text) do
    case normalized(words) do
      "" -> false
      quoted -> String.contains?(" #{normalized(owner_text)} ", " #{quoted} ")
    end
  end

  defp owned_loop(id, context, opts) do
    with {:ok, loop} <- Repo.get_open_loop(id, repo_opts(opts)) do
      if loop.owner_id == owner_id(context), do: {:ok, loop}, else: {:error, :not_found}
    end
  end

  defp live(%{state: state}) when state in @live, do: :ok
  defp live(_loop), do: {:error, :not_live}

  defp plan_at(nil, _loop, _hours, _now), do: {:ok, nil}

  defp plan_at(form, loop, hours, now) do
    case resolve_date(form, loop.timezone, now) do
      {:ok, %{kind: "date", date: date}} ->
        {:ok, ActiveHours.start_on(hours, date, loop.timezone)}

      {:ok, %{kind: "datetime", at: at}} ->
        {:ok, at}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_check(answer, loop, opts) when answer in ["plan", "not_yet"],
    do: Clock.stated_instant(loop.next_touch_at, opts)

  defp next_check(_answer, _loop, _opts), do: nil

  # --- list and view ---------------------------------------------------------

  @doc """
  The owner's loops: `state` `"live"` (the default: open, due, or asked and
  awaiting an answer), `"closed"` (the last 25 settled or expired) or `"any"`.
  Readable on the owner's private turn and inside a check-in run.
  """
  @spec list(map(), map(), keyword()) :: {:ok, [Repo.open_loop_row()]} | {:error, term()}
  def list(filter, context, opts \\ [])
      when is_map(filter) and is_map(context) and is_list(opts) do
    with :ok <- read_gate(context),
         {:ok, state} <- list_state(take(filter, [:state]).state) do
      Repo.list_open_loops(%{owner_id: owner_id(context), state: state}, repo_opts(opts))
    end
  end

  defp list_state(nil), do: {:ok, "live"}
  defp list_state(state) when state in @list_states, do: {:ok, state}
  defp list_state(_state), do: {:error, {:invalid_param, :state}}

  @doc """
  One loop as the model sees it: its words, its date stated absolutely, when
  and where the owner said it, its state and touches, the next check, and for
  a closed loop why and when it closed. Never a delivery destination, never a
  check-in's message text.

  Every time is stated on `FermixCore.Clock`, in the owner's current zone, the
  clock the current-date note reads, so the day it was said and "today" never
  disagree. The loop's own zone stays what its dates and checks are computed in.
  `opts` may carry `:personalization` in place of the application env.
  """
  @spec view(Repo.open_loop_row(), keyword()) :: map()
  def view(loop, opts \\ []) when is_map(loop) and is_list(opts) do
    %{
      "open_loop_id" => loop.id,
      "intention" => loop.intention,
      "why_it_matters" => loop.why_it_matters,
      "matters_by" => stated_matters_by(loop, opts),
      "said_on" => Clock.stated_day(loop.said_at, opts),
      "source_channel" => loop.source_channel,
      "state" => loop.state,
      "touches" => loop.touches,
      "next_check" => next_check_view(loop, opts),
      "last_answer" => loop.last_answer
    }
    |> Map.merge(closed_view(loop, opts))
  end

  @doc """
  `view/2` as a tool result shows a loop: the words of one noted after outside
  content are framed (`framed_intention/1`), as its due note frames them, since
  they may not be the owner's. `open_loop_list` and `open_loop_update` answer
  with it.
  """
  @spec result_view(Repo.open_loop_row()) :: map()
  def result_view(%{noted_after_outside_content: false} = loop), do: view(loop)

  def result_view(%{noted_after_outside_content: true} = loop),
    do: loop |> view() |> Map.put("intention", framed_intention(loop))

  @doc """
  A loop's words as data that may not be the owner's: JSON-quoted, so no quote
  or line break in them ends the quotation, inside the untrusted-content frame
  attributed to the tool that recorded them. Every place a stamped loop's words
  reach a model frames them this way.
  """
  @spec framed_intention(Repo.open_loop_row()) :: String.t()
  def framed_intention(%{intention: intention}) when is_binary(intention),
    do: UntrustedContent.frame("open_loop_note", Jason.encode!(intention))

  defp next_check_view(%{state: state} = loop, opts) when state in @live,
    do: Clock.stated_instant(loop.next_touch_at, opts)

  defp next_check_view(_closed, _opts), do: nil

  defp closed_view(%{state: state}, _opts) when state in @live, do: %{}

  defp closed_view(loop, opts) do
    %{
      "close_reason" => loop.close_reason,
      "closed_on" => Clock.stated_day(loop.closed_at, opts)
    }
  end

  # --- stated dates ----------------------------------------------------------

  # Always absolute, always with the weekday and the year: the statement is read
  # off the stored row, so it can only say what was written.
  defp stated_matters_by(%{matters_by_kind: "date"} = loop, _opts),
    do: Calendar.strftime(loop.matters_by_date, "%A, %B %-d, %Y")

  defp stated_matters_by(loop, opts), do: Clock.stated_instant(loop.matters_by_at, opts)

  # --- tagged date form (Temporal.Registry's vocabulary) ---------------------

  defp resolve_date(form, zone, now) when is_map(form) do
    form |> Map.new(fn {key, value} -> {to_string(key), value} end) |> resolve_form(zone, now)
  end

  defp resolve_date(form, _zone, _now), do: {:error, {:invalid_when, form}}

  defp resolve_form(%{"type" => "date", "date" => date} = form, zone, _now) do
    with {:ok, parsed} <- parse_date(date, form), do: {:ok, date_only(parsed, zone)}
  end

  defp resolve_form(%{"type" => "datetime", "date" => date, "time" => time} = form, zone, _now) do
    with {:ok, parsed_date} <- parse_date(date, form),
         {:ok, parsed_time} <- parse_time(time, form),
         {:ok, offset} <- utc_offset(Map.get(form, "utc_offset"), form) do
      timed(parsed_date, parsed_time, zone, offset)
    end
  end

  defp resolve_form(%{"type" => "relative", "unit" => unit}, _zone, _now)
       when unit in @clock_units,
       do: {:error, :not_dated}

  defp resolve_form(%{"type" => "relative", "amount" => amount, "unit" => unit} = form, zone, now) do
    with {:ok, days} <- relative_days(amount, unit, form) do
      date = now |> DateTime.shift_zone!(zone) |> DateTime.to_date() |> Date.add(days)
      relative_at(date, Map.get(form, "time"), zone, form)
    end
  end

  defp resolve_form(%{"type" => "annual"}, _zone, _now), do: {:error, :not_dated}
  defp resolve_form(form, _zone, _now), do: {:error, {:invalid_when, form}}

  defp date_only(date, zone) do
    %{
      kind: "date",
      date: date,
      time: nil,
      at: ActiveHours.local_instant(Date.add(date, 1), @day_start, zone)
    }
  end

  defp timed(date, time, zone, offset) do
    with {:ok, at} <- Planner.resolve_local_datetime(date, time, zone, offset) do
      {:ok, %{kind: "datetime", date: date, time: time, at: at}}
    end
  end

  defp relative_at(date, nil, zone, _form), do: {:ok, date_only(date, zone)}

  defp relative_at(date, time, zone, form) do
    with {:ok, parsed} <- parse_time(time, form), do: timed(date, parsed, zone, nil)
  end

  defp relative_days(amount, unit, form)
       when is_integer(amount) and amount > 0 and is_map_key(@relative_units, unit) do
    days = amount * Map.fetch!(@relative_units, unit)
    if days > @max_relative_days, do: {:error, {:invalid_when, form}}, else: {:ok, days}
  end

  defp relative_days(_amount, _unit, form), do: {:error, {:invalid_when, form}}

  defp parse_date(value, form) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, {:invalid_when, form}}
    end
  end

  defp parse_date(_value, form), do: {:error, {:invalid_when, form}}

  defp parse_time(value, form) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, Time.truncate(time, :second)}
      {:error, _reason} -> {:error, {:invalid_when, form}}
    end
  end

  defp parse_time(_value, form), do: {:error, {:invalid_when, form}}

  defp utc_offset(nil, _form), do: {:ok, nil}
  defp utc_offset(offset, _form) when is_binary(offset), do: {:ok, offset}
  defp utc_offset(_offset, form), do: {:error, {:invalid_when, form}}

  # --- timezone --------------------------------------------------------------

  # A zone the owner named wins; otherwise the owner's configured zone. Both go
  # through `FermixCore.Clock`, so an unknown name fails rather than becoming UTC.
  defp resolve_timezone(zone, _opts) when is_binary(zone) and zone != "",
    do: Clock.validate_zone(zone)

  defp resolve_timezone(nil, opts), do: Clock.zone(opts)

  defp resolve_timezone(other, _opts), do: {:error, {:invalid_timezone, other}}

  # --- delivery target -------------------------------------------------------

  # One rung decides, once: the owner inbox ladder. A notification-only target
  # cannot hold an answer, so it is no target; a chat target's adapter must
  # resolve now, as the send path will resolve it.
  defp delivery_target(opts) do
    case OwnerInbox.resolve(Keyword.take(opts, [:jobs_config, :configured_owners])) do
      :no_delivery_target ->
        {:error, :no_target}

      {:ok, %{platform: @notification_platform}} ->
        {:error, :no_target}

      {:ok, inbox} ->
        with {:ok, _adapter} <- resolve_adapter(inbox.platform, opts), do: {:ok, inbox}
    end
  end

  defp resolve_adapter(platform, opts) do
    channels =
      opts
      |> Keyword.get_lazy(:jobs_config, fn -> Application.get_env(:fermix_core, :jobs, []) end)
      |> Keyword.get(:delivery_channels, %{})

    ChannelSend.resolve_adapter(platform, channels: channels)
  end

  # --- context ---------------------------------------------------------------

  defp mutation_gate(context) do
    if Access.mutate?(context), do: :ok, else: {:error, :not_attended}
  end

  defp read_gate(context) do
    if Access.read?(context), do: :ok, else: {:error, :not_attended}
  end

  defp source(%{conversation_key: {channel, chat_id, scope}}) do
    case thread_component(scope) do
      {:ok, thread} -> {:ok, {to_string(channel), to_string(chat_id), thread}}
      :error -> {:error, :no_conversation}
    end
  end

  defp source(_context), do: {:error, :no_conversation}

  defp thread_component(:root), do: {:ok, "root"}
  defp thread_component(scope) when is_binary(scope) and scope != "", do: {:ok, scope}
  defp thread_component(scope) when is_integer(scope), do: {:ok, Integer.to_string(scope)}
  defp thread_component(_scope), do: :error

  defp owner_id(context), do: Map.get(context, :memory_owner_id, "default")
  defp agent_id(context), do: Map.get(context, :memory_agent_id, "main")

  defp session_id(%{session_id: id}) when is_binary(id), do: id
  defp session_id(_context), do: nil

  defp active_hours(agent_id, owner_id, zone, now, opts) do
    ActiveHours.resolve(repo_opts(opts), agent_id, owner_id, zone, now)
  end

  # --- params ----------------------------------------------------------------

  # The model's JSON arrives string-keyed and an internal caller's atom-keyed;
  # each known key is read once, in one shape.
  defp take(params, keys) do
    Map.new(keys, fn key -> {key, Map.get(params, key, Map.get(params, Atom.to_string(key)))} end)
  end

  defp required_present(params, keys) do
    case Enum.filter(keys, &blank?(Map.fetch!(params, &1))) do
      [] -> :ok
      missing -> {:error, {:missing_parameters, missing}}
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp bounded_text(value, key, max) when is_binary(value) do
    trimmed = String.trim(value)
    if byte_size(trimmed) > max, do: {:error, {:too_long, key, max}}, else: {:ok, trimmed}
  end

  defp bounded_text(_value, key, _max), do: {:error, {:invalid_param, key}}

  defp optional_text(nil, _key), do: {:ok, nil}

  defp optional_text(value, key) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      _text -> bounded_text(value, key, Defaults.why_it_matters_max())
    end
  end

  defp optional_text(_value, key), do: {:error, {:invalid_param, key}}

  @doc """
  The key a restated intention is recognised by: lowercased, punctuation
  stripped, whitespace collapsed, bounded to `Defaults.dedupe_key_max/0`
  bytes. An intention with nothing left is a missing intention.
  """
  @spec dedupe_key(String.t()) ::
          {:ok, String.t()} | {:error, {:missing_parameters, [:intention]}}
  def dedupe_key(intention) when is_binary(intention) do
    key = intention |> normalized() |> bound_bytes(Defaults.dedupe_key_max())

    if key == "", do: {:error, {:missing_parameters, [:intention]}}, else: {:ok, key}
  end

  # The one normalisation words are compared by: the dedupe key's, unbounded.
  defp normalized(text) do
    text
    |> String.downcase()
    |> String.replace(~r/\p{P}/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp bound_bytes(text, max) when byte_size(text) <= max, do: text

  defp bound_bytes(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      if byte_size(acc) + byte_size(grapheme) > max,
        do: {:halt, acc},
        else: {:cont, acc <> grapheme}
    end)
    |> String.trim_trailing()
  end

  # --- plumbing --------------------------------------------------------------

  defp now(opts) do
    opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.shift_zone!(@utc)
  end

  defp repo_opts(opts), do: [server: Keyword.get(opts, :repo, Repo)]
  defp repo_opts(opts, now), do: [server: Keyword.get(opts, :repo, Repo), now: now]

  defp notify(opts) do
    case Keyword.get(opts, :scheduler) do
      nil -> :ok
      pid when is_pid(pid) -> GenServer.cast(pid, :loop_changed)
      name when is_atom(name) -> signal_named(name)
    end
  end

  defp signal_named(name) do
    case Process.whereis(name) do
      nil ->
        Logger.warning(
          "OpenLoops.Registry: scheduler #{inspect(name)} is unavailable; the committed " <>
            "loop stands and the scheduler's next reconcile will pick it up."
        )

      pid ->
        GenServer.cast(pid, :loop_changed)
    end
  end

  # --- error vocabulary ------------------------------------------------------

  @doc """
  Renders every refusal as one sentence that tells the model what to do, so
  all three tools say the same thing.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error(:not_attended) do
    "Open loops are available only on the owner's attended, top-level turn in a private " <>
      "chat; group chats and guest, scheduled, background, delegated and check-in turns " <>
      "cannot record or settle one, so answer the message without it."
  end

  def describe_error(:disabled),
    do: "Open loops are turned off on this install, so do not record or mention one."

  def describe_error(:no_conversation) do
    "This turn has no conversation to record the loop against, so answer the owner " <>
      "without recording it."
  end

  def describe_error({:missing_parameters, keys}) do
    "#{Enum.join(keys, " and ")} is required; call again with it, taken from what the " <>
      "owner said."
  end

  def describe_error({:too_long, key, max}) do
    "#{key} must be at most #{max} bytes; shorten it to the owner's own words and call again."
  end

  def describe_error({:invalid_param, :state}),
    do: "state must be live, closed or any; call again with one of them."

  def describe_error({:invalid_param, key}),
    do: "#{key} is not valid; call again with a value the schema allows."

  def describe_error({:invalid_when, form}) do
    "#{inspect(form)} is not a supported date form; use " <>
      ~s({"type":"date","date":"YYYY-MM-DD"}, ) <>
      ~s({"type":"datetime","date":"YYYY-MM-DD","time":"HH:MM:SS"} with an optional ) <>
      ~s("utc_offset", or {"type":"relative","amount":2,"unit":"days"|"weeks"}.)
  end

  def describe_error(:not_dated) do
    "An open loop needs a calendar date by which it matters, so a timer in minutes or " <>
      "hours or a yearly date cannot be one; record it with the date the owner named, or " <>
      "not at all."
  end

  def describe_error(:date_passed) do
    "That date has already passed, so there is nothing to keep an eye on; answer the " <>
      "owner without recording a loop."
  end

  def describe_error(:timezone_not_configured) do
    "No timezone is configured; ask the owner for their IANA zone or have them set " <>
      "[fermix_core.personalization] timezone, then call again."
  end

  def describe_error({:invalid_timezone, zone}) do
    "#{inspect(zone)} is not a known IANA timezone; call again with the owner's zone " <>
      "name, or leave timezone out to use the configured one."
  end

  def describe_error({:dst_gap, zone, date, time}) do
    "#{time} on #{date} does not exist in #{zone} because the clocks skip it; ask the " <>
      "owner which time they mean."
  end

  def describe_error({:dst_ambiguous, offsets}) do
    "That local time happens twice when the clocks fall back; call again with " <>
      "utc_offset set to one of #{Enum.join(offsets, " or ")}."
  end

  def describe_error(:no_target) do
    "There is no chat inbox of the owner's where a check-in could be answered, so nothing " <>
      "was recorded; answer the owner's actual question and do not mention the loop."
  end

  def describe_error({:unsupported_delivery_platform, platform}) do
    "The owner's inbox is on #{platform}, which has no delivery channel configured, so " <>
      "nothing was recorded; answer the owner without mentioning the loop."
  end

  def describe_error({:invalid_delivery_adapter, adapter}) do
    "The owner's inbox adapter #{inspect(adapter)} cannot send, so nothing was recorded; " <>
      "answer the owner without mentioning the loop."
  end

  def describe_error(:too_many_loops) do
    "Fermix already keeps #{Defaults.max_live_loops()} open loops for the owner, so this " <>
      "one was not recorded; mention it only if the owner asks, and then offer to drop " <>
      "one they no longer need."
  end

  def describe_error(:imminent_without_window) do
    "That date is too close for Fermix to raise before it passes, so no loop was " <>
      "recorded; as with an imminent loop, store the reminder instead."
  end

  def describe_error(:not_found) do
    "No open loop of the owner's has that id; list them with open_loop_list and use one " <>
      "of their ids."
  end

  def describe_error(:not_live) do
    "That loop is already closed or expired and never reopens; if the owner states a new " <>
      "intention, record it as a new loop."
  end

  def describe_error(:already_asked) do
    "That loop is already raised and awaiting the owner's answer, or has had every check " <>
      "it gets, so there is nothing to record."
  end

  def describe_error(:missing_owner_words) do
    "owner_words is required for this answer; call again with the owner's own words it " <>
      "rests on, excerpted as just the clause."
  end

  def describe_error(:owner_words_not_in_message) do
    "This turn read content someone else could have written, so owner_words must be the " <>
      "owner's own words from the message they sent this turn, and these are not in it; " <>
      "nothing changed, so ask the owner and settle it from what they say."
  end

  def describe_error(:owner_words_unverifiable) do
    "This turn read content someone else could have written and carries no message the " <>
      "owner typed to check owner_words against, so nothing changed; leave the loop for " <>
      "the owner to settle in their chat."
  end

  def describe_error(:owner_words_too_long) do
    "owner_words must be at most #{Defaults.owner_words_max()} characters; excerpt just " <>
      "the clause the answer rests on and call again."
  end

  def describe_error(:plan_after_date) do
    "That plan is later than the loop's own date; ask the owner which date they mean " <>
      "before settling it."
  end

  def describe_error(:plan_requires_date) do
    "A plan needs plan_at, the date or datetime the owner named; call again with it, or " <>
      "settle not_yet if they named none."
  end

  def describe_error(:plan_passed) do
    "That plan time has already passed; if the owner named a later time today give it as " <>
      "a datetime, otherwise settle not_yet."
  end

  def describe_error(:plan_at_without_plan),
    do: "plan_at goes only with answer plan; call again without it."

  def describe_error({:invalid_answer, answer}) do
    "#{inspect(answer)} is not an answer; use done, plan, not_yet, stop, drop or asked."
  end

  def describe_error({:invalid, field, problem}) do
    "The loop's #{field} is #{problem}, so nothing changed; correct it and call again."
  end

  def describe_error(reason) do
    "Open loop storage failed (#{inspect(reason)}), so nothing changed; tell the owner it " <>
      "could not be saved and do not retry in this turn."
  end
end
