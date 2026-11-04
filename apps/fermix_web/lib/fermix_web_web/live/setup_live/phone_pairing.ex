defmodule FermixWebWeb.SetupLive.PhonePairing do
  @moduledoc """
  The browser setup's Phone dialog as a reducer over the daemon's answers, the
  guards an answer is held to before anything is drawn, and the words around it
  (M51 web setup pairing §1, §2).

  It is the web twin of the two apps' reducers (Linux `desktop/core/src/pairing.rs`,
  macOS `Settings/Phone/PhonePairing.swift`) and derives nothing the daemon
  publishes: which state a window is in, whether the channel runs and how a
  window ended are all read. It touches no process; `FermixWebWeb.SetupLive.Phone`
  makes the calls and draws the steps.

  A step is one of:

    * `:closed`: no dialog;
    * `{:waiting, session}`: a read in flight, on the window it waits on, if any;
    * `{:turn_on, turn_on}`: the channel is not running;
    * `{:scan, scan}`: the code, its link and the daemon's countdown;
    * `{:compare, compare}`: the phone waiting for the owner's decision;
    * `{:paired, name}`, `{:ended, ending}` and `:phones`.

  `reduce/2` answers the next step and the window it leaves open that nothing
  will show, which the page cancels.
  """

  alias FermixCore.Management.Protocol

  defmodule Link do
    @moduledoc """
    The pairing link the daemon hands back once. It carries the phone's one-time
    secret, so it is held here and nowhere else, and no print of it spells it:
    LiveView's crash report prints every assign.
    """
    @enforce_keys [:text]
    defstruct [:text]

    @type t :: %__MODULE__{text: String.t()}

    defimpl Inspect do
      def inspect(_link, _opts), do: "#PairingLink<withheld>"
    end
  end

  @link_prefix "fermix://pair?"
  @max_link_bytes 2_048
  @max_ttl_ms 120_000
  @max_field_bytes 128
  # Control characters, and the characters that draw text of their own: line
  # and paragraph separators, bidirectional controls and invisible ones. The
  # zero-width joiner and non-joiner stay allowed; emoji are spelled with them.
  @control ~r/[\x{0000}-\x{001F}\x{007F}-\x{009F}]/u
  @unseen ~r/[\x{061C}\x{200B}\x{200E}\x{200F}\x{2028}-\x{202E}\x{2060}-\x{2064}\x{2066}-\x{2069}\x{FEFF}]/u

  @ended_expired "The code expired. Pairing codes last two minutes."
  @ended_denied "You denied this phone."
  @ended_cancelled "Pairing was cancelled."
  @ended_elsewhere "A pairing code is already open somewhere else."
  @ended_unreadable "Fermix answered a pairing code this app cannot show."
  @checking "Checking"

  @type session_id :: String.t()
  @type turn_on :: %{action: :switch_on | :restart, refusal: String.t() | nil}
  @type ending :: %{sentence: String.t(), action: :pair_again | {:start_over, session_id | nil}}
  @type step ::
          :closed
          | {:waiting, session_id | nil}
          | {:turn_on, turn_on()}
          | {:scan, %{session: session_id, link: Link.t(), ttl_ms: non_neg_integer()}}
          | {:compare, map()}
          | {:paired, String.t()}
          | {:ended, ending()}
          | :phones
  @type answer ::
          {:status, map()}
          | {:started, map()}
          | {:busy, map() | nil}
          | {:session, map()}
          | {:refused, String.t()}
  @type read :: nil | {:ok, map()} | {:error, String.t()}

  @doc "The sentence an answer this page cannot show ends the dialog with."
  @spec unreadable_sentence() :: String.t()
  def unreadable_sentence, do: @ended_unreadable

  @doc "The next step for one daemon answer, and the window it abandons."
  @spec reduce(step(), answer()) :: {step(), session_id | nil}
  def reduce(_step, {:status, status}) when is_map(status), do: opening(status)
  def reduce(_step, {:started, view}) when is_map(view), do: started(view)
  def reduce(_step, {:busy, pairing}) when is_map(pairing) or is_nil(pairing), do: busy(pairing)
  def reduce(step, {:session, view}) when is_map(view), do: read(view, step)
  def reduce(_step, {:refused, sentence}) when is_binary(sentence), do: {ended(sentence), nil}

  @doc "The window a step shows, which a read follows and closing cancels."
  @spec open_session(step()) :: session_id | nil
  def open_session({:waiting, session}), do: session
  def open_session({:scan, %{session: session}}), do: session
  def open_session({:compare, %{session: session}}), do: session
  def open_session(_step), do: nil

  @doc """
  A refusal term from `FermixCore.Management.Mobile` or `Settings`, in the
  daemon's words: its own sentence where it carries one, otherwise the line the
  management protocol publishes for its code.
  """
  @spec refusal_sentence(tuple()) :: String.t()
  def refusal_sentence({:invalid_params, _field, sentence}) when is_binary(sentence), do: sentence

  def refusal_sentence({:unavailable, _capability, sentence}) when is_binary(sentence),
    do: sentence

  def refusal_sentence({:config_unreadable, sentence}) when is_binary(sentence), do: sentence

  # The socket answers an unknown section as invalid parameters, so does this.
  def refusal_sentence({:unknown_section, _section}),
    do: Map.fetch!(Protocol.error_messages(), :invalid_params)

  # Every other code is one the protocol words; a code it does not is a defect
  # here, and fails loud rather than reading as some other refusal.
  def refusal_sentence({code, _detail}) when is_atom(code),
    do: Map.fetch!(Protocol.error_messages(), code)

  # Pairing begins on the channel as it stands: a running channel opens the
  # window, one that is off is turned on first, and one that is on but not
  # running owes a restart. One held until setup is finished is owed no
  # restart, which would start nothing: the window is asked for, and the
  # daemon's refusal says what the channel waits for. A hold this page cannot
  # name is read as a page that predates the field reads it.
  defp opening(%{"started" => true}), do: {{:waiting, nil}, nil}
  defp opening(%{"hold" => "setup"}), do: {{:waiting, nil}, nil}
  defp opening(%{"enabled" => true}), do: {turn_on(:restart), nil}
  defp opening(_status), do: {turn_on(:switch_on), nil}

  defp turn_on(action), do: {:turn_on, %{action: action, refusal: nil}}

  # The link is read here and nowhere else: no later answer carries it.
  defp started(%{"state" => "awaiting_scan"} = view) do
    with session when is_binary(session) <- view["session_id"],
         ttl_ms when is_integer(ttl_ms) <- ttl(view["ttl_ms"]),
         %Link{} = link <- link(view["uri"]) do
      {{:scan, %{session: session, link: link, ttl_ms: ttl_ms}}, nil}
    else
      _unreadable -> unreadable(view)
    end
  end

  defp started(%{"state" => "failed"} = view), do: failed(view)
  defp started(view), do: unreadable(view)

  # A window is open somewhere else. A phone waiting there is resumed here; a
  # code waiting for a scan cannot be drawn again, since its link was given once.
  defp busy(%{"state" => "awaiting_decision", "session_id" => session}) when is_binary(session),
    do: {{:waiting, session}, nil}

  defp busy(pairing), do: {elsewhere(pairing && pairing["session_id"]), nil}

  defp elsewhere(session),
    do: {:ended, %{sentence: @ended_elsewhere, action: {:start_over, session}}}

  # A read about any window but the one this step shows changes nothing.
  defp read(%{"session_id" => id} = view, step) when is_binary(id) do
    if open_session(step) == id, do: read_state(view, id, step), else: {step, nil}
  end

  defp read(_view, step), do: {step, nil}

  defp read_state(%{"state" => "awaiting_scan"} = view, id, step), do: scanning(view, id, step)
  defp read_state(%{"state" => "awaiting_decision"} = view, id, _step), do: comparing(view, id)
  defp read_state(%{"state" => "approved"} = view, _id, _step), do: paired(view)

  defp read_state(%{"state" => state} = view, _id, _step)
       when state in ["denied", "expired", "cancelled"],
       do: ended_by(get_in(view, ["outcome", "reason"]))

  defp read_state(%{"state" => "failed"} = view, _id, _step), do: failed(view)
  defp read_state(view, _id, _step), do: unreadable(view)

  # Still waiting for a scan: the countdown moves on the daemon's clock. A window
  # this dialog did not open has no code to draw.
  defp scanning(view, _id, {:scan, scan}) do
    case remaining(view["ttl_ms"]) do
      nil -> unreadable(view)
      ttl_ms -> {{:scan, %{scan | ttl_ms: ttl_ms}}, nil}
    end
  end

  defp scanning(_view, id, _step), do: {elsewhere(id), nil}

  defp comparing(%{"request" => request} = view, id) when is_map(request) do
    with ttl_ms when is_integer(ttl_ms) <- remaining(view["ttl_ms"]),
         true <- digits?(request["sas"]),
         true <- field?(request["device_name"]) and field?(request["model"]),
         sentence when is_binary(sentence) <- get_in(request, ["attestation", "sentence"]) do
      {{:compare, compare(request, id, sentence, ttl_ms)}, nil}
    else
      _unreadable -> unreadable(view)
    end
  end

  defp comparing(view, _id), do: unreadable(view)

  defp compare(request, id, hardware, ttl_ms) do
    %{
      session: id,
      device_name: request["device_name"],
      model: request["model"],
      digits: request["sas"],
      hardware: hardware,
      ttl_ms: ttl_ms
    }
  end

  defp paired(view) do
    name = get_in(view, ["request", "device_name"])
    if field?(name), do: {{:paired, name}, nil}, else: {ended(@ended_unreadable), nil}
  end

  defp ended_by("timeout"), do: {ended(@ended_expired), nil}
  defp ended_by("denied"), do: {ended(@ended_denied), nil}
  defp ended_by("cancelled"), do: {ended(@ended_cancelled), nil}
  defp ended_by(_reason), do: {ended(@ended_unreadable), nil}

  defp failed(%{"failure" => %{"sentence" => sentence}}) when is_binary(sentence),
    do: {ended(sentence), nil}

  defp failed(_view), do: {ended(@ended_unreadable), nil}

  defp ended(sentence), do: {:ended, %{sentence: sentence, action: :pair_again}}

  # An answer this page cannot show. A window it leaves open is cancelled.
  defp unreadable(view) do
    open = if terminal?(view), do: nil, else: view["session_id"]
    {ended(@ended_unreadable), if(is_binary(open), do: open)}
  end

  defp terminal?(view),
    do: view["state"] in ["approved", "denied", "expired", "cancelled", "failed"]

  defp link(text) when is_binary(text) do
    shaped? =
      String.starts_with?(text, @link_prefix) and byte_size(text) <= @max_link_bytes and
        String.valid?(text) and not Regex.match?(@control, text)

    if shaped?, do: %Link{text: text}
  end

  defp link(_text), do: nil

  defp ttl(ms) when is_integer(ms) and ms >= 1 and ms <= @max_ttl_ms, do: ms
  defp ttl(_ms), do: nil

  # The daemon counts a window down to zero before it says the window expired.
  defp remaining(ms) when is_integer(ms) and ms >= 0 and ms <= @max_ttl_ms, do: ms
  defp remaining(_ms), do: nil

  defp digits?(sas) when is_binary(sas), do: Regex.match?(~r/\A[0-9]{6}\z/, sas)
  defp digits?(_sas), do: false

  # A phone's name or model: the phone writes both, and Compare draws them above
  # the digits the owner approves by.
  defp field?(value) when is_binary(value) do
    value != "" and byte_size(value) <= @max_field_bytes and String.valid?(value) and
      not Regex.match?(@control, value) and not Regex.match?(@unseen, value)
  end

  defp field?(_value), do: false

  @doc """
  The Phone row: its status line and what its one button opens. `status` and
  `devices` are `nil` until they answer, or the daemon's sentence where it refused.
  """
  @spec row(read(), read()) :: %{status: String.t(), opens: :pair | :phones}
  def row(nil, _devices), do: %{status: @checking, opens: :pair}
  def row({:error, sentence}, _devices), do: %{status: sentence, opens: :pair}
  def row({:ok, status}, devices), do: status_row(status, devices)

  defp status_row(%{"enabled" => false}, _devices), do: %{status: "Off", opens: :pair}

  defp status_row(%{"hold" => "setup"}, _devices),
    do: %{status: "Starts once setup is finished", opens: :pair}

  defp status_row(%{"started" => false, "refused" => false}, _devices),
    do: %{status: "Restart to turn on", opens: :pair}

  defp status_row(status, devices) do
    cond do
      status["refused"] or get_in(status, ["listener", "status"]) == "unavailable" ->
        %{status: "Could not start", opens: :pair}

      status["paired_devices"] in [0, nil] ->
        %{status: "No phone paired", opens: :pair}

      status["paired_devices"] == 1 ->
        %{status: phone_name(devices), opens: :phones}

      true ->
        %{status: "#{status["paired_devices"]} phones", opens: :phones}
    end
  end

  defp phone_name({:ok, %{"devices" => [%{"name" => name} | _rest]}}) when is_binary(name),
    do: name

  defp phone_name({:error, sentence}), do: sentence
  defp phone_name(_devices), do: @checking

  @doc ~S|"Expires in 1:45": the daemon's `ttl_ms` rounded up, so an open window never reads 0:00.|
  @spec countdown(integer()) :: String.t()
  def countdown(ttl_ms) when is_integer(ttl_ms) do
    seconds = div(max(ttl_ms, 0) + 999, 1000)

    "Expires in #{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc ~S|The six digits in threes, as the phone draws them: "481 062".|
  @spec grouped(String.t()) :: String.t()
  def grouped(digits) when is_binary(digits) do
    {first, second} = String.split_at(digits, div(String.length(digits), 2))
    "#{first} #{second}"
  end

  @doc "The digits one by one after the phone's name, as a screen reader reads them."
  @spec spoken(String.t(), String.t()) :: String.t()
  def spoken(digits, name) when is_binary(digits) and is_binary(name),
    do: "#{name}, #{digits |> String.graphemes() |> Enum.join(" ")}"

  @doc """
  When a paired phone was last seen, in its largest unit, against `now` in Unix
  seconds. `nil` for a time this page cannot read, so the row says nothing untrue.
  """
  @spec seen(String.t() | nil, integer()) :: String.t() | nil
  def seen(nil, _now), do: "Not seen yet"

  def seen(last_seen, now) when is_binary(last_seen) and is_integer(now) do
    case DateTime.from_iso8601(last_seen) do
      {:ok, at, _offset} -> ago(now - DateTime.to_unix(at))
      {:error, _reason} -> nil
    end
  end

  @units [
    {365 * 86_400, "year"},
    {30 * 86_400, "month"},
    {86_400, "day"},
    {3_600, "hour"},
    {60, "minute"}
  ]

  defp ago(seconds) do
    case Enum.find(@units, fn {size, _unit} -> seconds >= size end) do
      nil ->
        "Seen just now"

      {size, unit} ->
        "Seen #{div(seconds, size)} #{unit}#{if div(seconds, size) == 1, do: "", else: "s"} ago"
    end
  end

  @doc "Under a paired phone's name: its model, and when it was seen where that reads."
  @spec detail(String.t(), String.t() | nil, integer()) :: String.t()
  def detail(model, last_seen, now) when is_binary(model) do
    case seen(last_seen, now) do
      nil -> model
      words -> "#{model} · #{words}"
    end
  end

  @doc """
  The line under Reach from anywhere, from `mobile.status.remote`: a note, a
  start that moves on by itself, or the daemon's failure as written. A rail that
  is off, or a state this page does not know, says nothing beyond its switch.
  """
  @spec reach_line(map() | nil) :: {String.t(), :note | :progress | :failure} | nil
  def reach_line(%{"state" => "helper_missing"}), do: {"Not included in this build.", :note}
  def reach_line(%{"state" => "dormant"}), do: {"Starts when you pair your first phone.", :note}
  def reach_line(%{"state" => "starting"}), do: {"Starting…", :progress}

  def reach_line(%{"state" => "ready", "connected" => true}),
    do: {"Connected to Fermix's relays.", :note}

  def reach_line(%{"state" => "ready"}),
    do: {"Not connected to Fermix's relays right now.", :note}

  def reach_line(%{"state" => "failed", "failure" => failure}) when is_binary(failure),
    do: {failure, :failure}

  def reach_line(_remote), do: nil

  @doc "Whether the rail can move while nobody touches its switch, so its line is followed."
  @spec reach_moves?(map() | nil) :: boolean()
  def reach_moves?(%{"state" => state}) when state in ["off", "dormant", "helper_missing"],
    do: false

  def reach_moves?(%{"state" => _state}), do: true
  def reach_moves?(_remote), do: false
end
