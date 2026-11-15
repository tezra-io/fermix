defmodule FermixCore.Native.Notifications.Computers do
  @moduledoc """
  Notifications on the owner's computers (M99 §10.1): the backend an Always On
  server's primary resolves (`Native.Notifications.placement/1`), which has no
  notification centre of its own. Each notification is asked of every
  connected computer over the link it keeps, one invocation of the
  `notifications` capability each (`Computers.Capabilities.Notifications`),
  and the computer's own engine posts it the same local way a home there
  would: the Mac app's native host, or the Linux session bus.

  **Who is asked.** The home's computers (`Computers.fetch/1`), the connected
  ones, at most #{16}, in the order of their names; each once, at most #{8}
  at a time, each within #{20} s, so a post across all of them ends inside the
  rail's 60 s watchdog. A request is a reminder's, never a turn's: its origin
  is `background`, its turn named for the reminder (`reminder-<id>`).

  **`post/2`** carries the notification's key, and a computer shows one key
  once, so a retry after a lost answer shows nothing twice. Shown on at least
  one computer is delivered (`{:ok, key}`). Otherwise the first reason the
  rail retries (`Native.Notifications.delivery_error/1`): a computer that
  could not be reached, was busy, did not answer in time or lost its answer
  is `:timeout`, and its backend's own transient reasons are themselves.
  Otherwise the first computer's reason, in name order: its switch is off
  (`:not_authorized`), its engine does not know notifications or refused the
  request from an older copy of the home (`{:failed, words}`), or its
  backend's own. A home with no computer linked is `:not_offered`, one with
  none connected `:no_computer`, which the rail retries while the reminder is
  valid: a Mac asleep now may be awake then.

  A refusal the computer made carries its receipt; one the server made before
  the request reached it (it went away, it has not said what it offers) does
  not. The wire's `unavailable` from the computer is its engine saying no (it
  does not know the op, it restarted before it ran, it cannot read its link),
  never told apart there, so it is never retried; from the server it is a
  computer that could not be reached.

  **`ready/2`**, asked as a reminder is stored: refused when no computer is
  linked, or when the computers cannot be listed; accepted when none is
  connected; otherwise each connected computer is asked `ready` and it is
  accepted unless every one of them says it cannot show one (one that could
  not be asked has not said so), refused then in the first one's clause.

  Seams in `opts`: `:computers` (`Computers.fetch/1`'s options), `:call` (6-
  arity, in place of `Computers.call/6`), `:call_opts` (options for every
  call: its `Calls`, transport and epoch) and `:tasks` (the
  `Task.Supervisor` the calls run under).
  """

  @behaviour FermixCore.Native.Notifications

  require Logger

  alias FermixCore.Computers
  alias FermixCore.Computers.Capabilities.Notifications, as: Capability
  alias FermixCore.Computers.Computer
  alias FermixCore.Computers.Outcome
  alias FermixCore.Delivery.Error
  alias FermixCore.Native.Notifications

  @max_computers 16
  @max_concurrency 8
  @call_timeout_ms 20_000

  @none_linked "no computer is linked to your server"
  @not_listed "your computers could not be listed now"

  # The reasons a computer's backend answers in, by their wire words; any
  # other word fails with the computer's own words.
  @reasons %{
    "not_authorized" => :not_authorized,
    "no_server" => :no_server,
    "host_unavailable" => :host_unavailable,
    "timeout" => :timeout,
    "backend_missing" => :backend_missing,
    "not_offered" => :not_offered
  }

  @doc """
  Whether a notification could be shown on one of the owner's computers now
  (the moduledoc). A refusal is one clause, as `Native.Notifications` asks.
  """
  @impl true
  @spec ready(map(), keyword()) :: :ok | {:error, String.t()}
  def ready(context, opts) when is_map(context) and is_list(opts) do
    case linked(opts) do
      {:ok, []} -> {:error, @none_linked}
      {:ok, computers} -> computers |> awake() |> readiness(context, opts)
      {:error, _reason} -> {:error, @not_listed}
    end
  end

  @doc """
  Shows one notification on every connected computer (the moduledoc),
  answering its key once one showed it, or the reason the rail reads.
  """
  @impl true
  @spec post(Notifications.notification(), keyword()) ::
          {:ok, Notifications.id()} | {:error, Notifications.reason()}
  def post(%{title: title, body: body, sound: sound} = notification, opts)
      when is_binary(title) and title != "" and is_binary(body) and is_boolean(sound) and
             is_list(opts) do
    with {:ok, key} <- key(notification),
         {:ok, targets} <- post_targets(opts) do
      targets
      |> ask("post", post_args(notification, key), post_context(notification, key), opts)
      |> Enum.map(&posted/1)
      |> combined(key)
    end
  end

  # -- the computers ------------------------------------------------------------------

  defp linked(opts) do
    case Computers.fetch(Keyword.get(opts, :computers, [])) do
      {:ok, computers} ->
        {:ok, computers}

      {:error, reason} ->
        Logger.warning(
          "notifications: the home's computers could not be listed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # The connected ones, in name order as the home lists them.
  defp awake(computers),
    do: computers |> Enum.filter(& &1.connected) |> Enum.take(@max_computers)

  defp post_targets(opts) do
    case linked(opts) do
      {:ok, []} ->
        Logger.warning("a notification was not shown: #{@none_linked}")
        {:error, :not_offered}

      {:ok, computers} ->
        awake_targets(awake(computers))

      {:error, _reason} ->
        {:error, :no_computer}
    end
  end

  defp awake_targets([]) do
    Logger.info("a notification waits: none of your computers is connected")
    {:error, :no_computer}
  end

  defp awake_targets(computers), do: {:ok, computers}

  # One call per computer, at most `@max_concurrency` at a time, each ended
  # past its bound: answered in the order the computers were given.
  defp ask(computers, op, args, context, opts) do
    call = Keyword.get(opts, :call, &Computers.call/6)

    call_opts =
      opts
      |> Keyword.get(:call_opts, [])
      |> Keyword.put(:deadline_ms, Capability.deadline_ms(op, args))

    opts
    |> Keyword.get(:tasks, FermixCore.TaskSupervisor)
    |> Task.Supervisor.async_stream_nolink(
      computers,
      &call.(&1, Capability, op, args, context, call_opts),
      max_concurrency: @max_concurrency,
      timeout: @call_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.zip(computers)
    |> Enum.map(fn
      {{:ok, answer}, computer} -> {computer, answer}
      {{:exit, reason}, computer} -> {computer, {:exit, reason}}
    end)
  end

  # -- a post ---------------------------------------------------------------------------

  defp key(%{key: key}) when is_binary(key) and key != "", do: {:ok, key}

  defp key(_notification),
    do: {:error, {:failed, "a notification for your computers carries no key"}}

  defp post_args(notification, key) do
    %{"key" => key, "title" => notification.title, "body" => notification.body}
    |> Map.put("sound", notification.sound)
    |> put_reminder(Map.get(notification, :reminder_id))
  end

  defp put_reminder(args, nil), do: args
  defp put_reminder(args, id) when is_binary(id), do: Map.put(args, "reminder_id", id)

  # A reminder's request, no turn's: `background`, its turn named for it.
  defp post_context(notification, key) do
    case Map.get(notification, :reminder_id) do
      id when is_binary(id) -> %{session_id: "reminder-" <> id}
      nil -> %{session_id: "notification-" <> key}
    end
  end

  defp posted({computer, answer}) do
    reason = post_reason(computer, answer)
    :ok = log_post(computer, answer, reason)
    {computer, reason}
  end

  defp combined(answers, key) do
    case for({_computer, reason} <- answers, reason != :shown, do: reason) do
      reasons when length(reasons) < length(answers) -> {:ok, key}
      [first | _rest] = reasons -> {:error, Enum.find(reasons, first, &retried?/1)}
    end
  end

  defp retried?(reason), do: Error.retryable?(Notifications.delivery_error(reason))

  # What one computer's answer is, as the rail reads it (the moduledoc).
  defp post_reason(_computer, {:ok, %Outcome{result: %{"shown" => shown}}})
       when shown in ["now", "before"],
       do: :shown

  # Its journal says it ran, and its answer is no longer held there.
  defp post_reason(_computer, {:ok, %Outcome{receipt_only: true}}), do: :shown

  defp post_reason(%Computer{name: name}, {:ok, %Outcome{}}),
    do: {:failed, "#{name} answered outside the contract"}

  defp post_reason(computer, {:error, %Outcome{} = outcome}), do: unshown(computer, outcome)
  defp post_reason(_computer, {:exit, _reason}), do: :timeout

  # Failed with nothing more than its journal's word: why is not known, and a
  # post that failed let go of its key, so asking again is safe.
  defp unshown(_computer, %Outcome{status: :failed, receipt_only: true}), do: :timeout

  defp unshown(computer, %Outcome{status: :failed, result: %{"reason" => word}} = outcome)
       when is_binary(word),
       do: Map.get(@reasons, word, {:failed, said(computer, outcome)})

  defp unshown(computer, %Outcome{status: :failed} = outcome),
    do: {:failed, said(computer, outcome)}

  defp unshown(_computer, %Outcome{status: :refused, refusal: :busy}), do: :timeout

  # Refused before the request reached the computer: it went away, or has
  # not said yet what it offers.
  defp unshown(_computer, %Outcome{status: :refused, refusal: :unavailable, receipt: nil}),
    do: :timeout

  defp unshown(_computer, %Outcome{status: :refused, refusal: refusal})
       when refusal in [:off, :stopped_here],
       do: :not_authorized

  defp unshown(computer, %Outcome{status: :refused} = outcome),
    do: {:failed, said(computer, outcome)}

  defp unshown(_computer, %Outcome{status: status})
       when status in [:timed_out, :unknown, :cancelled],
       do: :timeout

  defp log_post(%Computer{name: name}, _answer, :shown) do
    Logger.info("a notification showed on #{name}")
  end

  defp log_post(%Computer{name: name} = computer, answer, reason) do
    Logger.warning(
      "a notification did not show on #{name} (#{inspect(reason)}): #{answer_words(computer, answer)}"
    )
  end

  defp answer_words(%Computer{name: name}, {_tag, %Outcome{} = outcome}),
    do: Outcome.sentence(outcome, name)

  defp answer_words(_computer, {:exit, reason}),
    do: "the call ended: #{inspect(reason, limit: 5, printable_limit: 200)}"

  # The computer's own words, naming it.
  defp said(%Computer{name: name}, %Outcome{message: message}), do: "#{name}: #{message}"

  # -- readiness ------------------------------------------------------------------------

  defp readiness([], _context, _opts), do: :ok

  defp readiness(computers, context, opts) do
    answers = computers |> ask("ready", %{}, context, opts) |> Enum.map(&ready_answer/1)

    if Enum.any?(answers, &(&1 in [:ready, :unsure])),
      do: :ok,
      else: {:error, answers |> hd() |> elem(1)}
  end

  defp ready_answer({computer, {:ok, %Outcome{result: %{"ready" => true}}}}) do
    Logger.debug("#{computer.name} can show a notification")
    :ready
  end

  defp ready_answer({computer, {:ok, %Outcome{result: %{"ready" => false, "sentence" => said}}}})
       when is_binary(said),
       do: {:no, "#{computer.name} answers that #{said}"}

  defp ready_answer({computer, {:ok, %Outcome{}}}),
    do: {:no, "#{computer.name} answered outside the contract"}

  # One that could not be asked has not said it cannot show one.
  defp ready_answer({computer, answer}) do
    if retried?(post_reason(computer, answer)),
      do: unsure(computer, answer),
      else: {:no, "#{computer.name} answers that #{clause(answer)}"}
  end

  defp unsure(computer, answer) do
    Logger.info(
      "#{computer.name} was not asked whether it can show a notification: " <>
        answer_words(computer, answer)
    )

    :unsure
  end

  # The computer's own sentence as a clause: no final period, lowercase
  # unless it starts with "Fermix".
  defp clause({:error, %Outcome{message: message}}) when is_binary(message) do
    text = message |> String.trim() |> String.trim_trailing(".")

    if String.starts_with?(text, "Fermix"),
      do: text,
      else: lower_first(text)
  end

  defp clause({:error, %Outcome{}}), do: "it cannot show one now"

  defp lower_first(<<first::utf8, rest::binary>>), do: String.downcase(<<first::utf8>>) <> rest
  defp lower_first(""), do: "it cannot show one now"
end
