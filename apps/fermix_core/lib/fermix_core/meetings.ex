defmodule FermixCore.Meetings do
  @moduledoc """
  The meetings subsystem's public surface: the notetaker joins a meeting,
  leaves it, and lists what it has been to (MILESTONE_21 C2 §1).

  Everything the tool layer needs is here, and nothing else reaches into the
  Session tree. `join/2` is the whole admission decision, and it is written as
  an ordered gate chain so a refusal names the one thing that is wrong rather
  than failing deep inside a browser or a websocket handshake:

    1. the subsystem is enabled;
    2. the caller is the owner on an attended, top-level turn;
    3. the URL is a meeting URL this daemon can place;
    4. the lane that URL needs is actually installed or configured;
    5. no other meeting is running (`@max_concurrent` is 1 — the notetaker has
       one pair of ears);
    6. only then is a row written and a Session started.

  Gate 5 is a read, so it cannot be the whole answer: the Session claims the one
  capacity slot in its own `init/1`, and a join that loses that race is refused
  with the same `{:max_concurrent, id}` this gate returns.

  Gate 2 is defence in depth beneath the tool's `:external_api` policy class,
  and it is the *same* predicate the temporal event tools use
  (`Temporal.Access.attended_operator_turn?/1`) rather than a second hand-rolled
  copy: a guest, a background run, a delegated worker, and a coding
  continuation are refused here exactly as they are refused there.

  `join/2` returns as soon as the Session process exists. Everything after that
  — joining, admission, capture, summary, delivery — is the Session's own
  lifecycle, observable through the meetings row and the meeting telemetry.
  """

  require Logger

  alias FermixCore.Meetings.Config
  alias FermixCore.Meetings.Link
  alias FermixCore.Meetings.RtmsSource
  alias FermixCore.Meetings.Session
  alias FermixCore.Meetings.SidecarInstaller
  alias FermixCore.Meetings.SidecarSource
  alias FermixCore.Meetings.Store
  alias FermixCore.Meetings.Supervisor, as: MeetingsSupervisor
  alias FermixCore.Temporal.Access

  # The notetaker captures one audio stream, so it attends one meeting.
  @max_concurrent 1

  @default_limit 20
  @list_max 50

  @id_bytes 8

  @type meeting :: Store.meeting()

  @type join_error ::
          :meetings_disabled
          | :operator_only
          | :unrecognized_meeting_url
          | :sidecar_not_installed
          | :meet_browser_not_installed
          | :zoom_rtms_not_configured
          | {:max_concurrent, String.t()}
          | term()

  @doc "Whether the meetings subsystem is enabled — the config toggle alone."
  @spec enabled?() :: boolean()
  def enabled?, do: Config.enabled?()

  @doc """
  Whether meetings can actually be joined, which is what gates tool
  registration: enabled AND at least one lane usable. A config-only enable
  advertises nothing until the Meet sidecar is installed or the Zoom RTMS
  credentials are complete.
  """
  @spec ready?() :: boolean()
  def ready?, do: ready?(Config.load())

  @doc """
  Whether the Meet lane can actually place a bot: the sidecar AND the browser it
  drives. One answer, shared by readiness, the join gate, and the doctor row —
  an installed sidecar with no browser is not a usable lane.
  """
  @spec meet_lane_ready?() :: boolean()
  def meet_lane_ready? do
    SidecarInstaller.installed?() and SidecarInstaller.browser_installed?()
  end

  @doc """
  Requests that the notetaker join `url`.

  `opts`: `:title` (the operator's name for the meeting), `:context` (the
  calling turn's context — it must carry the trust and origin markers gate 2
  reads), `:requested_by` (default `"operator"`), and `:store_opts` /
  `:session_opts`, the seams the suite uses to point a meeting at its own Repo
  and its own scripted capture lane.
  """
  @spec join(String.t(), keyword()) ::
          {:ok, %{id: String.t(), status: atom()}} | {:error, join_error()}
  def join(url, opts \\ []) when is_binary(url) and is_list(opts) do
    config = Config.load()
    context = Keyword.get(opts, :context, %{})

    with :ok <- check_enabled(config),
         :ok <- check_operator(context),
         {:ok, link} <- Link.parse(url),
         :ok <- check_lane(link.platform, config),
         :ok <- check_capacity(),
         {:ok, meeting} <- insert(url, link, context, opts) do
      start_inserted_session(meeting, link, config, context, opts)
    end
  end

  # The row is inserted before the Session starts, so a start failure (the
  # documented capacity-slot race, a refused spawn) must fail the row in place
  # — otherwise `list_meetings(scope: :active)` reports a phantom meeting that
  # `leave` cannot clear (`:not_active`) until the next boot sweep.
  defp start_inserted_session(meeting, link, config, context, opts) do
    case start_session(meeting, link, config, context, opts) do
      {:ok, _pid} ->
        {:ok, %{id: meeting.id, status: :requested}}

      {:error, reason} = error ->
        fail_stranded_row(meeting.id, reason, opts)
        error
    end
  end

  defp fail_stranded_row(id, reason, opts) do
    fields = %{ended_at: DateTime.utc_now(), error: "session start failed: #{inspect(reason)}"}

    case Store.update_status(id, "failed", fields, store_opts(opts)) do
      {:ok, _meeting} ->
        :ok

      {:error, update_reason} ->
        Logger.error(
          "meetings: #{id} session start failed AND the row could not be failed " <>
            "(#{inspect(update_reason)}); the boot sweep will clear it"
        )
    end
  end

  @doc """
  Asks the running meeting to wind down: leave the meeting, summarize what was
  captured, deliver the notes.

  `:not_active` means the row exists but no Session does — the meeting already
  reached a terminal state, so there is nothing left to leave.
  """
  @spec leave(String.t(), keyword()) :: :ok | {:error, :not_found | :not_active}
  def leave(id, opts \\ []) when is_binary(id) do
    case lookup(id) do
      {:ok, pid} -> Session.leave(pid)
      :error -> inactive_or_missing(id, opts)
    end
  end

  @doc """
  Lists meetings, newest first.

  `opts`: `scope: :active | :recent` (default `:recent`) and `limit` (default
  #{@default_limit}, clamped to #{@list_max}).
  """
  @spec list(keyword()) :: {:ok, [meeting()]} | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    filter = %{
      scope: Keyword.get(opts, :scope, :recent),
      limit: clamp_limit(Keyword.get(opts, :limit, @default_limit))
    }

    Store.list(filter, store_opts(opts))
  end

  @doc "One meeting row by id."
  @spec get(String.t(), keyword()) :: {:ok, meeting()} | {:error, :not_found | term()}
  def get(id, opts \\ []) when is_binary(id), do: Store.get(id, store_opts(opts))

  @doc """
  The ids of the meetings with a live Session right now (at most
  `#{@max_concurrent}`).
  """
  @spec active_ids() :: [String.t()]
  def active_ids do
    # Meeting ids are the registry's binary keys; the Session's capacity slot is
    # registered in the same registry under an atom key and is not a meeting.
    Registry.select(MeetingsSupervisor.registry(), [
      {{:"$1", :_, :_}, [{:is_binary, :"$1"}], [:"$1"]}
    ])
  end

  # --- gates ----------------------------------------------------------------

  defp check_enabled(%{enabled: true}), do: :ok
  defp check_enabled(_config), do: {:error, :meetings_disabled}

  defp check_operator(context) do
    if Access.attended_operator_turn?(context), do: :ok, else: {:error, :operator_only}
  end

  # Two halves, two reasons. The sidecar is the binary; the browser is what it
  # drives. An installed sidecar with no browser used to pass this gate and die
  # once the session tried to launch Chromium, so the failure arrived as a dead
  # meeting rather than a refusal naming the one thing to install.
  defp check_lane(:meet, _config) do
    cond do
      not SidecarInstaller.installed?() -> {:error, :sidecar_not_installed}
      not SidecarInstaller.browser_installed?() -> {:error, :meet_browser_not_installed}
      true -> :ok
    end
  end

  defp check_lane(:zoom, config) do
    if Config.rtms_configured?(config), do: :ok, else: {:error, :zoom_rtms_not_configured}
  end

  # The fast path only: it reads the registry before the new Session exists, so
  # two joins racing each other can both pass it. `Session.init/1` claims the
  # slot atomically and refuses the loser with this same error.
  defp check_capacity do
    case active_ids() do
      ids when length(ids) < @max_concurrent -> :ok
      [id | _rest] -> {:error, {:max_concurrent, id}}
    end
  end

  defp ready?(config) do
    config.enabled and (meet_lane_ready?() or Config.rtms_configured?(config))
  end

  # --- start ----------------------------------------------------------------

  defp insert(url, link, context, opts) do
    attrs = %{
      id: mint_id(),
      platform: Atom.to_string(link.platform),
      url: url,
      title: Keyword.get(opts, :title),
      requested_by: Keyword.get(opts, :requested_by, "operator"),
      origin_session_id: origin_session_id(context),
      created_at: DateTime.utc_now()
    }

    Store.insert(attrs, store_opts(opts))
  end

  defp start_session(meeting, link, config, context, opts) do
    child = {Session, session_opts(meeting, link, config, context, opts)}
    DynamicSupervisor.start_child(MeetingsSupervisor.session_supervisor(), child)
  end

  defp session_opts(meeting, link, config, context, opts) do
    [
      name: {:via, Registry, {MeetingsSupervisor.registry(), meeting.id}},
      meeting: meeting,
      link: link,
      config: config,
      parent_session: Map.get(context, :session_id),
      source_module: source_module(link.platform),
      store_opts: store_opts(opts)
    ]
    |> Keyword.merge(Keyword.get(opts, :session_opts, []))
  end

  # One lane per platform, decided once, here. Nothing downstream branches on
  # the platform and nothing falls back to the other lane.
  defp source_module(:meet), do: SidecarSource
  defp source_module(:zoom), do: RtmsSource

  # `Jobs.Scheduler`'s id shape: 8 random bytes, url-safe, 11 characters. The
  # suffix is the whole point of the id and is never truncated.
  defp mint_id do
    "mtg_" <> (@id_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  # The delivery origin, in the shape `Meetings.Delivery` resolves: a meeting
  # asked for in a conversation reports back to that conversation. The
  # `schedule_job` derivation, so the two subsystems answer "where did this come
  # from" the same way.
  defp origin_session_id(%{conversation_key: {channel, chat_id, thread_scope}}) do
    Enum.map_join([channel, chat_id, thread_scope], ":", &target_part/1)
  end

  defp origin_session_id(context), do: Map.get(context, :session_id)

  defp target_part(:root), do: "root"
  defp target_part(value) when is_binary(value), do: value
  defp target_part(value) when is_integer(value), do: Integer.to_string(value)
  defp target_part(value) when is_atom(value), do: Atom.to_string(value)

  # --- lookup ---------------------------------------------------------------

  defp lookup(id) do
    case Registry.lookup(MeetingsSupervisor.registry(), id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp inactive_or_missing(id, opts) do
    case Store.get(id, store_opts(opts)) do
      {:ok, _meeting} -> {:error, :not_active}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @list_max)
  defp clamp_limit(limit), do: limit

  defp store_opts(opts), do: Keyword.get(opts, :store_opts, [])
end
