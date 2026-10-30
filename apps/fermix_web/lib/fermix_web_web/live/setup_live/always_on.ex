defmodule FermixWebWeb.SetupLive.AlwaysOn do
  @moduledoc """
  The browser setup's Always On tab (M75 §14, B14): everything the apps'
  Always On pane shows, for a host with no app, and the device role's word on
  the rest of the page.

  It calls what the management methods call, in the page's own process, and
  derives nothing: `Management.Home.status/1` (`home.status`) is the picture
  every card draws; `Management.Home.snapshots_run/1` and
  `snapshots_passphrase/2` back up now and set the recovery passphrase;
  `Management.HomeMove.enroll_open/1` opens an enrollment code and
  `move_readiness/2` reviews a move before anything starts it;
  `Management.Settings` serves the `snapshots` section; and
  `Management.Secrets.set/2` stores the two S3 keys.

  On the primary the move is offered as its command, shown once its review
  has nothing that blocks, not as a button: starting it restarts the engine
  that serves this page in the device role, which only a service manager
  brings back, and the command (`fermix home move`) handles a stopped engine
  and reads the passphrase from a file or asks for it without echo. The tab
  says when to add `--retire`: on a server that is itself the primary, being
  replaced, which then keeps no desktop of the new one.

  On a desktop linked to its primary (`FermixCore.Home.DesktopLink.linked?/2`,
  decided once per opening of the page, as the daemon decides it once per
  boot) the picture carries the primary's own (`primary_home`, or
  `primary_missing` with why it is not there), and what the tab does to the
  server goes there over the link the daemon forwards through
  (`FermixCore.Home.Link`): backing it up now, and replacing it, which is a
  code from the server, the review of the move and the move itself with
  `keep_as_desktop` false, so the server it replaces keeps no desktop of its
  own. That move restarts the server and never this computer, so it is a
  button here.

  Secrets never come back: the passphrase fields and the key fields are
  rendered empty, their form is replaced after every submission so the
  browser clears it, their parameter names are ones the Phoenix log filter
  drops, and nothing here keeps or logs them. The enrollment code is shown once,
  until Done or the tab is left.

  Times are drawn in the viewer's own zone, named, when the browser gave it at
  connect (`viewer_zone/1`), and in UTC otherwise; the daemon's own sentences
  keep the zone they were written in.

  All of its state is the page's one `:always_on` assign. While something on
  the tab moves by itself (an open enrollment window, a move under way, a
  snapshot being written, here or on the server) it is read again every five
  seconds, at most #{120} times per opening; every read carries the tab's
  generation, so a read for an older opening is dropped.

  Seams, under `config :fermix_web, :always_on`: `home` (options for every
  `Management.Home` and `HomeMove` call), `settings` (for `Settings`),
  `schedule` (how a later read is scheduled),
  `linked?` (whether this computer is a linked desktop, in place of
  `DesktopLink.linked?/2`) and `forward` (the way to the primary, in place of
  `FermixCore.Home.Link.impl().forward/2`).
  """

  use FermixWebWeb, :html

  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Link
  alias FermixCore.Home.Role
  alias FermixCore.Management.Home
  alias FermixCore.Management.HomeMove
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol
  alias FermixCore.Management.Secrets
  alias FermixCore.Management.Settings, as: ManagementSettings
  alias FermixCore.Setup.ConfigStore

  require Logger

  @docs_url "https://fermix.ai/docs/always-on"
  @existing_host_command "curl -fsSL https://fermix.ai/always-on | sudo sh"
  @poll_ms 5_000
  @max_reads 120
  # A move under way, and the two endings recorded just before an engine
  # restarts: the engine that comes back publishes how it ended.
  @pending_phases ~w(requested streaming committing aborting committed undoing)
  @storage_kinds ~w(text number choice)
  @unverified_sentence "Fermix cannot check these."
  @mismatch_sentence "The two passphrases differ, so nothing was saved."
  @not_waiting_sentence "That server is no longer waiting for the move. Read the list again."
  @review_first_sentence "Review the move to that server first; it starts once nothing blocks it."
  @card "rounded-box border border-base-300 bg-base-100/80 p-5 shadow-sm"

  # What the owner weighs before choosing to move, said where the choice is.
  @before_moving [
    "The move needs about twice this home's size free on this computer, and as " <>
      "much again on the server.",
    "While it runs this computer serves nothing: Fermix restarts here as a desktop " <>
      "of the server, and a message typed meanwhile waits until the move is done.",
    "Telegram messages sent during the move are lost, and a recurring job more than " <>
      "an hour late is skipped.",
    "The server keeps your secrets in files, behind its disk encryption and Fermix's " <>
      "sandbox: encrypt its disk if its host does not. The secrets in this computer's " <>
      "keychain move into those files.",
    "Moving back to a desktop is not in this version: to bring Fermix back to a " <>
      "computer, restore the newest snapshot into a fresh home there."
  ]
  @replacing [
    "The move needs about twice the home's size free on the server you replace, and " <>
      "as much again on the new one.",
    "While it runs neither server serves anything, and a message typed here waits " <>
      "until the move is done.",
    "Telegram messages sent during the move are lost, and a recurring job more than " <>
      "an hour late is skipped.",
    "The new server keeps your secrets in files, behind its disk encryption and " <>
      "Fermix's sandbox: encrypt its disk if its host does not.",
    "The server you replace serves nothing once the move is done, and is no desktop " <>
      "of the new one; delete it then."
  ]
  @moving_back "Moving back to a desktop is not in this version: to bring Fermix back to " <>
                 "a computer, restore the newest snapshot into a fresh home there."
  @moving_back_here "Moving Fermix back to this computer is not in this version: to bring " <>
                      "it back, restore the newest snapshot into a fresh home here."
  @secrets_here "Fermix cannot read these secrets on this host, so whatever uses them " <>
                  "fails until you enter each again in its tab on this page."
  @secrets_on_server "The server cannot read these secrets, so whatever uses them fails " <>
                       "until you enter each again in the Fermix app."

  # Each tab of the page by the management request its controls make, so the
  # one placement table (`Management.Placement`) decides which engine serves
  # it. A tab missing here fails loud rather than being served by default.
  @tab_requests %{
    "provider" => {"settings.apply", "providers.openai"},
    "realtime" => {"settings.apply", "realtime"},
    "channels" => {"settings.apply", "channels.telegram"},
    "transcription" => {"settings.apply", "transcription"},
    "plugins" => {"plugins.list", nil},
    "search" => {"settings.apply", "web_search"},
    "media" => {"settings.apply", "generate_image"},
    "sandbox" => {"settings.apply", "sandbox"},
    "coding" => {"settings.apply", "harness"},
    "memory" => {"settings.apply", "memory"},
    "personalization" => {"settings.apply", "personalization"},
    "cues" => {"settings.apply", "cues"},
    "always_on" => {"home.status", nil},
    "doctor" => {"doctor.start", nil}
  }

  @type write :: :written | nil

  # -- the device role's word on the page ----------------------------------------

  @doc """
  The tabs the primary serves, which a device-role page shows as unavailable
  rather than editable: none off the device role.
  """
  @spec primary_tabs(Role.record(), [%{id: String.t()}]) :: [String.t()]
  def primary_tabs(%{role: :device}, tabs) when is_list(tabs) do
    for %{id: id} <- tabs, place(Map.fetch!(@tab_requests, id)) == :primary, do: id
  end

  def primary_tabs(%{role: role}, tabs) when role in [:primary, :candidate] and is_list(tabs),
    do: []

  defp place({method, nil}), do: Placement.place(method, %{})
  defp place({method, section}), do: Placement.place(method, %{"section" => section})

  # The primary's own setup page is unreachable from here on most servers (it
  # listens on the server's loopback only), so the page points at the app.
  @doc "The notice a device-role page leads with, or nil off the device role."
  @spec device_notice(Role.record()) :: String.t() | nil
  def device_notice(%{role: :device} = record) do
    "This computer runs Fermix as a desktop of #{primary_words(record)}. Fermix-wide " <>
      "settings live on the primary: change them in the Fermix app on this computer. " <>
      "This page sets up this computer."
  end

  def device_notice(%{role: role}) when role in [:primary, :candidate], do: nil

  @doc "The sentence a tab the primary serves shows in the device role."
  @spec unavailable_sentence(Role.record()) :: String.t()
  def unavailable_sentence(%{role: :device} = record) do
    "These settings are Fermix-wide, so they live on #{primary_words(record)}. Change them " <>
      "in the Fermix app on this computer."
  end

  defp primary_words(%{primary: name}) when is_binary(name) and name != "",
    do: "the primary, #{name}"

  defp primary_words(_record), do: "the primary"

  # -- state ---------------------------------------------------------------------

  @doc """
  The tab's state before anything is read, for the role the page booted in and
  the viewer's time zone (`viewer_zone/1`, nil for UTC).
  """
  @spec initial(Role.record(), String.t() | nil) :: map()
  def initial(%{role: role} = record, zone \\ nil)
      when role in [:primary, :device, :candidate] and (is_binary(zone) or is_nil(zone)) do
    %{
      record: record,
      linked?: linked?(record),
      zone: zone,
      status: nil,
      storage: nil,
      code: nil,
      review: nil,
      notices: %{},
      form_gen: 0,
      gen: 0,
      reads: 0,
      polling?: false
    }
  end

  @doc """
  The viewer's time zone, as the browser gave it at connect (`timezone`), when
  the zone database knows it; nil before the socket connects and for anything
  else, so the tab draws UTC and says so.
  """
  @spec viewer_zone(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def viewer_zone(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: known_zone(Phoenix.LiveView.get_connect_params(socket)["timezone"]),
      else: nil
  end

  defp known_zone(zone) when is_binary(zone) and byte_size(zone) in 1..64 do
    case DateTime.shift_zone(~U[2026-01-01 00:00:00Z], zone) do
      {:ok, _at} -> zone
      {:error, _reason} -> nil
    end
  end

  defp known_zone(_zone), do: nil

  @doc "Reads the picture and the sections afresh, and follows what moves by itself."
  @spec load(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def load(socket) do
    socket
    |> update(&%{read(&1) | gen: &1.gen + 1, reads: 0, polling?: false})
    |> schedule_poll()
  end

  @doc """
  The page moved to `tab`: the Always On tab is read afresh; leaving it drops
  a code still shown and a review, and stops following the picture.
  """
  @spec on_tab(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def on_tab(socket, "always_on"), do: load(socket)

  def on_tab(socket, _tab),
    do: update(socket, &%{&1 | code: nil, review: nil, gen: &1.gen + 1, polling?: false})

  defp read(state) do
    %{
      state
      | status: Home.status(home_opts(state)),
        storage: storage_rows(state.record)
    }
  end

  # The snapshot section is the primary's: a device forwards it, so this page,
  # which sets up this computer, draws it only on the primary.
  defp storage_rows(%{role: :primary}), do: read_rows("snapshots")
  defp storage_rows(_record), do: nil

  defp read_rows(section) do
    case ManagementSettings.get(section, settings_opts()) do
      {:ok, %{"rows" => rows}} -> {:ok, rows}
      {:error, refusal} -> {:error, refusal(refusal)}
    end
  end

  # -- events --------------------------------------------------------------------

  @doc """
  One `always_on_*` event. Answers the socket and `:written` where it wrote
  the settings file, so the page refreshes its report.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {Phoenix.LiveView.Socket.t(), write()}
  def handle_event("always_on_refresh", _params, socket), do: {load(socket), nil}
  def handle_event("always_on_enroll", _params, socket), do: enroll(socket)
  def handle_event("always_on_code_done", _params, socket), do: {put(socket, :code, nil), nil}
  def handle_event("always_on_backup", _params, socket), do: backup(socket)

  def handle_event("always_on_review", %{"candidate" => id}, socket) when is_binary(id),
    do: review(socket, id)

  def handle_event("always_on_review_done", _params, socket), do: {put(socket, :review, nil), nil}

  def handle_event(
        "always_on_passphrase",
        %{"always_on_passphrase" => %{"password" => first, "password_again" => second}},
        socket
      )
      when is_binary(first) and is_binary(second),
      do: passphrase(socket, first, second)

  def handle_event(
        "always_on_replace",
        %{
          "always_on_replace" => %{
            "candidate" => id,
            "password" => first,
            "password_again" => second
          }
        },
        socket
      )
      when is_binary(id) and is_binary(first) and is_binary(second),
      do: replace(socket, id, first, second)

  def handle_event("always_on_storage", %{"always_on_storage" => fields}, socket)
      when is_map(fields),
      do: storage(socket, fields)

  def handle_event("always_on_keys", %{"secret" => keys}, socket) when is_map(keys),
    do: keys(socket, keys)

  # Anything else is not an event this tab draws: it changes nothing, and only
  # its name reaches the log, never its parameters.
  def handle_event(event, _params, socket) do
    Logger.warning("setup always on: ignored a malformed #{event} event")
    {socket, nil}
  end

  @doc "A scheduled read of the picture."
  @spec handle_info(tuple(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle_info({:always_on_poll, gen}, %{assigns: %{always_on: %{gen: gen}}} = socket),
    do: poll(socket)

  def handle_info({:always_on_poll, _stale}, socket), do: socket

  defp enroll(socket) do
    state = socket.assigns.always_on
    local = fn -> HomeMove.enroll_open(home_opts(state)) end

    case on_primary(state, "home.enroll.open", %{}, local) do
      {:ok, %{"code" => code, "expires_at" => expires_at}} ->
        socket = socket |> load() |> put(:code, %{code: code, expires_at: expires_at})
        {put_notice(socket, :enrollment, nil), nil}

      {:error, sentence} ->
        {put_notice(socket, :enrollment, {:error, sentence}), nil}
    end
  end

  defp backup(socket) do
    state = socket.assigns.always_on
    local = fn -> Home.snapshots_run(home_opts(state)) end

    case on_primary(state, "home.snapshots.run", %{}, local) do
      {:ok, %{"started" => true}} ->
        {socket |> load() |> put_notice(:recovery, {:info, "A snapshot is being written now."}),
         nil}

      {:error, sentence} ->
        {put_notice(socket, :recovery, {:error, sentence}), nil}
    end
  end

  # The review of a move to one of the servers the picture lists, on the
  # primary or, from a linked desktop, on the server it would replace.
  defp review(socket, id) do
    state = socket.assigns.always_on
    local = fn -> HomeMove.move_readiness(id, home_opts(state)) end

    if Enum.any?(held(state), &(&1["candidate_id"] == id)) do
      case on_primary(state, "home.move.readiness", %{"candidate_id" => id}, local) do
        {:ok, %{"ready" => ready, "items" => items}} when is_boolean(ready) and is_list(items) ->
          review = %{candidate_id: id, ready: ready, items: items}
          {socket |> put(:review, review) |> put_notice(:candidates, nil), nil}

        {:error, sentence} ->
          {put_notice(socket, :candidates, {:error, sentence}), nil}
      end
    else
      {put_notice(socket, :candidates, {:error, @not_waiting_sentence}), nil}
    end
  end

  # The two fields are compared here and nowhere else; the passphrase goes to
  # the one function `home.snapshots.passphrase` calls and is dropped with the
  # event. The form is replaced either way, so the browser clears both fields.
  defp passphrase(socket, first, second) when first != second,
    do: {socket |> clear_forms() |> put_notice(:passphrase, {:error, @mismatch_sentence}), nil}

  defp passphrase(socket, first, _second) do
    state = socket.assigns.always_on
    changing? = get_in(picture(state), ["snapshots", "recipient_set"]) == true
    socket = clear_forms(socket)

    case Home.snapshots_passphrase(first, home_opts(state)) do
      {:ok, %{"sentence" => sentence}} ->
        {socket |> load() |> put_notice(:passphrase, {:info, saved(changing?, sentence)}),
         :written}

      {:error, refusal} ->
        {put_notice(socket, :passphrase, {:error, refusal(refusal)}), nil}
    end
  end

  # A changed passphrase also says which snapshots open with which, in the
  # daemon's words.
  defp saved(changing?, sentence) do
    kept =
      "The recovery passphrase is set. Keep it somewhere safe: Fermix keeps only the " <>
        "key made from it, and no snapshot opens without it."

    if changing?, do: kept <> " " <> sentence, else: kept
  end

  # The move that replaces the server: only from a linked desktop, only to a
  # server whose review here had nothing that blocks, with the two passphrases
  # equal. The passphrase goes to the server with the request and is dropped
  # with the event; the form is replaced either way.
  defp replace(socket, id, first, second) do
    state = socket.assigns.always_on
    socket = clear_forms(socket)

    cond do
      not ready_review?(state, id) ->
        {put_notice(socket, :replace, {:error, @review_first_sentence}), nil}

      first != second ->
        {put_notice(socket, :replace, {:error, @mismatch_sentence}), nil}

      true ->
        start_replace(socket, state, id, first)
    end
  end

  defp start_replace(socket, state, id, passphrase) do
    params = %{
      "candidate_id" => id,
      "recovery_passphrase" => passphrase,
      "keep_as_desktop" => false
    }

    case forwarded(state, "home.move.start", params) do
      {:ok, %{"candidate" => %{"name" => name}}} ->
        started =
          "The server is moving this home to #{name}, and serves nothing once it is done. " <>
            "This computer follows the home there; keep the recovery passphrase somewhere safe."

        {socket |> put(:review, nil) |> load() |> put_notice(:replace, {:info, started}), nil}

      {:error, sentence} ->
        {put_notice(socket, :replace, {:error, sentence}), nil}
    end
  end

  defp ready_review?(%{linked?: true, review: %{candidate_id: id, ready: true}}, id), do: true
  defp ready_review?(_state, _id), do: false

  defp storage(socket, fields) do
    with {:ok, rows} <- current(socket.assigns.always_on.storage),
         {:ok, changes} <- changes(rows, fields),
         {:ok, written} <- apply_storage(changes) do
      {socket |> load() |> put_notice(:storage, {:info, written_sentence(written)}), written}
    else
      {:error, sentence} -> {put_notice(socket, :storage, {:error, sentence}), nil}
    end
  end

  defp written_sentence(:written), do: "Saved."
  defp written_sentence(nil), do: "Nothing changed."

  defp apply_storage(changes) when map_size(changes) == 0, do: {:ok, nil}

  defp apply_storage(changes) do
    case ManagementSettings.apply("snapshots", changes, settings_opts()) do
      {:ok, _result} -> {:ok, :written}
      {:error, refusal} -> {:error, refusal(refusal)}
    end
  end

  # Only the section's own secret rows are stored, and only those typed in; an
  # empty field keeps what is stored. The values go to `secret.set`'s function
  # and are dropped with the event.
  defp keys(socket, typed) do
    case current(socket.assigns.always_on.storage) do
      {:ok, rows} -> socket |> clear_forms() |> store_keys(entered(rows, typed))
      {:error, sentence} -> {put_notice(socket, :keys, {:error, sentence}), nil}
    end
  end

  defp entered(rows, typed) do
    for %{"kind" => "secret", "key" => key} <- rows,
        value = typed[key],
        is_binary(value) and String.trim(value) != "",
        do: {key, String.trim(value)}
  end

  defp store_keys(socket, []), do: {put_notice(socket, :keys, {:info, "Nothing changed."}), nil}

  defp store_keys(socket, entered) do
    case Enum.find_value(entered, &store_key/1) do
      nil -> {socket |> load() |> put_notice(:keys, {:info, "The keys are stored."}), :written}
      sentence -> {socket |> load() |> put_notice(:keys, {:error, sentence}), :written}
    end
  end

  defp store_key({key, value}) do
    case Secrets.set(key, value) do
      {:ok, _presence} -> nil
      {:error, refusal} -> refusal(refusal)
    end
  end

  # -- the primary: here, or over the link ---------------------------------------

  # A request about the primary's home: answered by this engine on the
  # primary, and by the primary itself, over the link, on a linked desktop.
  # Either answer is the result or the sentence a person is shown.
  defp on_primary(%{linked?: true} = state, method, params, _local),
    do: forwarded(state, method, params)

  defp on_primary(_state, _method, _params, local), do: answered(local.())

  defp answered({:ok, result}), do: {:ok, result}
  defp answered({:error, refusal}), do: {:error, refusal(refusal)}

  defp forwarded(%{linked?: true}, method, params) do
    request = %{
      request_id: "always-on-" <> Integer.to_string(System.unique_integer([:positive])),
      protocol_version: Protocol.protocol_version(),
      method: method,
      params: params
    }

    case forward().(request, []) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, code, details} when is_atom(code) -> {:error, forwarded_sentence(code, details)}
    end
  end

  defp forwarded_sentence(_code, %{"sentence" => sentence}) when is_binary(sentence),
    do: sentence

  defp forwarded_sentence(code, _details), do: Map.fetch!(Protocol.error_messages(), code)

  # The servers a review may name: the primary's own, or on a linked desktop
  # the ones its primary holds.
  defp held(%{status: {:ok, %{"role" => "primary", "candidates" => candidates}}})
       when is_list(candidates),
       do: candidates

  defp held(%{linked?: true, status: {:ok, %{"primary_home" => %{"candidates" => candidates}}}})
       when is_list(candidates),
       do: candidates

  defp held(_state), do: []

  defp picture(%{status: {:ok, picture}}), do: picture
  defp picture(_state), do: %{}

  # -- the storage form ----------------------------------------------------------

  defp current({:ok, rows}), do: {:ok, rows}
  defp current({:error, sentence}), do: {:error, sentence}
  defp current(nil), do: {:error, "The snapshot settings are the primary's."}

  # Every value is read against the row it names before anything is written,
  # and only a value that differs from the row's is sent. A key that is not a
  # writable row of the section is not taken.
  defp changes(rows, fields) do
    rows
    |> Enum.filter(&storage_row?/1)
    |> Enum.filter(&Map.has_key?(fields, &1["key"]))
    |> Enum.reduce_while({:ok, %{}}, fn row, {:ok, acc} ->
      case field_value(row, fields[row["key"]]) do
        {:ok, value} -> {:cont, {:ok, changed(acc, row, value)}}
        {:error, sentence} -> {:halt, {:error, sentence}}
      end
    end)
  end

  # An empty text field is the row's empty value, which the section stores as
  # absent: nothing to send while the row holds nothing either.
  defp changed(acc, %{"value" => value}, value), do: acc
  defp changed(acc, %{"value" => nil}, ""), do: acc
  defp changed(acc, %{"key" => key}, value), do: Map.put(acc, key, value)

  defp storage_row?(row), do: row["kind"] in @storage_kinds and row["read_only"] != true

  defp field_value(%{"kind" => "number", "label" => label}, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> {:error, "#{label} takes a whole number."}
    end
  end

  defp field_value(%{"kind" => kind}, value) when kind in ["text", "choice"] and is_binary(value),
    do: {:ok, String.trim(value)}

  defp field_value(%{"label" => label}, _value), do: {:error, "#{label} cannot take that value."}

  # -- following the picture -----------------------------------------------------

  defp poll(socket) do
    socket
    |> update(&%{read(&1) | reads: &1.reads + 1, polling?: false})
    |> schedule_poll()
  end

  defp schedule_poll(socket) do
    state = socket.assigns.always_on

    if Phoenix.LiveView.connected?(socket) and moving?(state.status) and
         state.reads < @max_reads and not state.polling? do
      schedule({:always_on_poll, state.gen}, @poll_ms)
      put(socket, :polling?, true)
    else
      socket
    end
  end

  # Here, or on the server a linked desktop shows.
  defp moving?({:ok, picture}),
    do: moves_by_itself?(picture) or moves_by_itself?(picture["primary_home"])

  defp moving?(_status), do: false

  defp moves_by_itself?(%{} = picture) do
    get_in(picture, ["enrollment", "state"]) == "open" or
      get_in(picture, ["move", "phase"]) in @pending_phases or
      get_in(picture, ["snapshots", "running"]) == true
  end

  defp moves_by_itself?(_none), do: false

  # -- refusals ------------------------------------------------------------------

  # A refusal from a management function, in the daemon's words: its own
  # sentence where it carries one, otherwise the line the protocol publishes
  # for its code. A code the protocol does not word fails loud.
  defp refusal({:invalid_params, _field, sentence}) when is_binary(sentence), do: sentence
  defp refusal({:unavailable, _capability, sentence}) when is_binary(sentence), do: sentence
  defp refusal({:secret_store_failed, _reason, sentence}) when is_binary(sentence), do: sentence
  defp refusal({:config_unreadable, sentence}) when is_binary(sentence), do: sentence

  defp refusal({:unknown_section, _section}),
    do: Map.fetch!(Protocol.error_messages(), :invalid_params)

  defp refusal(refusal) when is_tuple(refusal),
    do: Map.fetch!(Protocol.error_messages(), elem(refusal, 0))

  # -- state and seams -----------------------------------------------------------

  defp clear_forms(socket), do: update(socket, &%{&1 | form_gen: &1.form_gen + 1})

  defp put_notice(socket, area, nil),
    do: update(socket, &%{&1 | notices: Map.delete(&1.notices, area)})

  defp put_notice(socket, area, {tone, text}) when tone in [:info, :error] and is_binary(text),
    do: update(socket, &%{&1 | notices: Map.put(&1.notices, area, {tone, text})})

  defp put(socket, key, value), do: update(socket, &Map.put(&1, key, value))
  defp update(socket, fun), do: Phoenix.Component.update(socket, :always_on, fun)

  defp seams, do: Application.get_env(:fermix_web, :always_on, [])

  # A linked desktop's picture carries the primary's own, asked over the link.
  defp home_opts(%{record: record, linked?: linked?}) do
    opts = seams() |> Keyword.get(:home, []) |> Keyword.put_new(:engine_role, record)
    if linked?, do: Keyword.put_new(opts, :primary_forward, forward()), else: opts
  end

  defp settings_opts, do: Keyword.get(seams(), :settings, [])

  defp linked?(record) do
    case Keyword.fetch(seams(), :linked?) do
      {:ok, linked?} when is_boolean(linked?) -> linked?
      :error -> DesktopLink.linked?(record, ConfigStore.fermix_home())
    end
  end

  defp forward, do: Keyword.get(seams(), :forward, &forward_to_primary/2)
  defp forward_to_primary(request, opts), do: Link.impl().forward(request, opts)

  defp schedule(message, wait_ms) do
    case Keyword.get(seams(), :schedule) do
      nil -> Process.send_after(self(), message, wait_ms)
      schedule when is_function(schedule, 2) -> schedule.(message, wait_ms)
    end

    :ok
  end

  # -- reads, for drawing --------------------------------------------------------

  defp rows({:ok, rows}), do: rows
  defp rows(_rows), do: []

  # A time the daemon gave, as the viewer reads it: the whole minute in their
  # zone (checked when the page connected), named; UTC without one.
  defp clock(nil, _zone), do: nil

  defp clock(iso, zone) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> local(at, zone)
      {:error, _reason} -> iso
    end
  end

  defp local(at, nil), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp local(at, zone) do
    {:ok, shifted} = DateTime.shift_zone(at, zone)
    Calendar.strftime(shifted, "%Y-%m-%d %H:%M ") <> zone_name(shifted)
  end

  # The zone's own abbreviation where it has one in letters (CET, PDT),
  # otherwise its name: some zones abbreviate only as an offset.
  defp zone_name(%DateTime{zone_abbr: abbr, time_zone: zone}) do
    if Regex.match?(~r/\A[A-Z]{2,5}\z/, abbr), do: abbr, else: zone
  end

  defp review_for(%{review: %{candidate_id: id} = review}, id), do: review
  defp review_for(_state, _id), do: nil

  # -- drawing -------------------------------------------------------------------

  attr :always_on, :map, required: true

  @doc "The Always On tab."
  def pane(assigns) do
    ~H"""
    <div id="always-on-pane" class="space-y-6">
      <.title />
      <.body :if={@always_on.status} state={@always_on} />
    </div>
    """
  end

  defp title(assigns) do
    assigns = assign(assigns, docs: @docs_url)

    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-3">
      <div class="min-w-0">
        <h2 class="text-2xl font-semibold tracking-normal">Always On</h2>
        <p class="mt-1 text-sm text-base-content/70">
          Fermix on a server you control, so it keeps working with this computer closed.
        </p>
      </div>
      <div class="flex gap-1">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="always_on_refresh">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh
        </button>
        <a href={@docs} target="_blank" rel="noopener noreferrer" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-book-open" class="size-4" /> Docs
        </a>
      </div>
    </div>
    """
  end

  attr :state, :map, required: true

  defp body(assigns) do
    {:ok, picture} = assigns.state.status

    assigns =
      assign(assigns,
        picture: picture,
        role: picture["role"],
        secrets: List.wrap(picture["secrets_missing"]),
        secrets_here: @secrets_here
      )

    ~H"""
    <.secrets_missing
      :if={@secrets != []}
      id="always-on-secrets-missing"
      ids={@secrets}
      sentence={@secrets_here}
    />
    <.this_computer picture={@picture} />
    <.link_card :if={@role == "device"} picture={@picture} zone={@state.zone} />
    <.move_card :if={@picture["move"]} id="always-on-move" title="The move" move={@picture["move"]} />
    <%= if @role == "primary" do %>
      <.recovery state={@state} snapshots={@picture["snapshots"]} server?={false} />
      <.enrollment state={@state} enrollment={@picture["enrollment"]} replacing?={false} />
      <.candidates state={@state} candidates={@picture["candidates"]} replacing?={false} />
      <.desktops state={@state} desktops={@picture["desktops"]} />
    <% end %>
    <.server :if={@role == "device" and @state.linked?} state={@state} picture={@picture} />
    """
  end

  attr :id, :string, required: true
  attr :ids, :list, required: true
  attr :sentence, :string, required: true

  # The secret references that did not resolve, by the ids the settings take,
  # never a value.
  defp secrets_missing(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <section id={@id} class={[@card, "border-warning/50"]} role="alert">
      <h3 class="text-sm font-semibold">Secrets to enter again</h3>
      <p class="mt-1 text-sm text-base-content/70">{@sentence}</p>
      <ul class="mt-2 flex flex-wrap gap-1.5">
        <li :for={id <- @ids}>
          <code class="rounded-field bg-base-200 px-1.5 py-0.5 font-mono text-xs">{id}</code>
        </li>
      </ul>
    </section>
    """
  end

  attr :picture, :map, required: true

  defp this_computer(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <section id="always-on-engine" class={@card}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold">This computer</h3>
          <p id="always-on-role" class="mt-0.5 text-sm">{@picture["role"]}</p>
        </div>
        <span id="always-on-epoch" class="badge badge-ghost badge-sm shrink-0">
          {if @picture["epoch"], do: "Epoch #{@picture["epoch"]}", else: "No epoch yet"}
        </span>
      </div>
    </section>
    """
  end

  attr :picture, :map, required: true
  attr :zone, :string, default: nil

  defp link_card(%{picture: %{"primary" => %{} = primary}} = assigns) do
    assigns = assign(assigns, primary: primary, card: @card)

    ~H"""
    <section id="always-on-primary" class={@card}>
      <h3 class="text-sm font-semibold">The primary</h3>
      <div class="mt-1 flex flex-wrap items-center gap-2">
        <span class="text-sm font-medium">{@primary["name"]}</span>
        <.dot
          :if={@primary["connected"]}
          tone="bg-success"
          text={"Connected since #{clock(@primary["since"], @zone)}"}
        />
        <.dot
          :if={@primary["status"] == "renewing"}
          tone="bg-base-content/30"
          text="Reconnecting"
        />
        <.dot
          :if={!@primary["connected"] and @primary["status"] != "renewing"}
          tone="bg-error"
          text="Not connected"
        />
      </div>
      <p class="mt-1 text-sm text-base-content/70">{@primary["sentence"]}</p>
    </section>
    """
  end

  defp link_card(%{picture: %{"moved" => %{} = moved}} = assigns) do
    assigns =
      assign(assigns, moved: moved, at: clock(moved["moved_at"], assigns.zone), card: @card)

    ~H"""
    <section id="always-on-primary" class={@card}>
      <h3 class="text-sm font-semibold">The primary</h3>
      <p class="mt-1 text-sm text-base-content/70">
        This home moved to {@moved["to"]} on {@at} at epoch {@moved["epoch"]}.
        This computer has no link to it.
      </p>
    </section>
    """
  end

  defp link_card(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <section id="always-on-primary" class={@card}>
      <h3 class="text-sm font-semibold">The primary</h3>
      <p class="mt-1 text-sm text-base-content/70">
        This computer runs in the device role with no link to a primary.
      </p>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :move, :map, required: true

  defp move_card(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <section id={@id} class={@card}>
      <div class="flex flex-wrap items-center gap-2">
        <h3 class="text-sm font-semibold">{@title}</h3>
        <span id={"#{@id}-phase"} class="badge badge-sm badge-ghost">{@move["phase"]}</span>
      </div>
      <p id={"#{@id}-sentence"} class="mt-1 text-sm text-base-content/70">
        {@move["sentence"]}
      </p>
    </section>
    """
  end

  attr :state, :map, required: true
  attr :picture, :map, required: true

  # A linked desktop: the server's own home, as it answered over the link, or
  # why it did not.
  defp server(%{picture: %{"primary_home" => %{} = home}} = assigns) do
    assigns =
      assign(assigns,
        home: home,
        secrets: List.wrap(home["secrets_missing"]),
        secrets_on_server: @secrets_on_server
      )

    ~H"""
    <.secrets_missing
      :if={@secrets != []}
      id="always-on-server-secrets-missing"
      ids={@secrets}
      sentence={@secrets_on_server}
    />
    <.move_card
      :if={@home["move"]}
      id="always-on-server-move"
      title="The server's move"
      move={@home["move"]}
    />
    <.recovery state={@state} snapshots={@home["snapshots"]} server?={true} />
    <.enrollment state={@state} enrollment={@home["enrollment"]} replacing?={true} />
    <.candidates state={@state} candidates={List.wrap(@home["candidates"])} replacing?={true} />
    """
  end

  defp server(%{picture: %{"primary_missing" => sentence}} = assigns) when is_binary(sentence) do
    assigns = assign(assigns, card: @card, sentence: sentence, moving_back: @moving_back_here)

    ~H"""
    <section id="always-on-server-missing" class={@card}>
      <h3 class="text-sm font-semibold">The server's home</h3>
      <p class="mt-1 text-sm text-base-content/70">{@sentence}</p>
      <p class="mt-2 text-xs text-base-content/60">{@moving_back}</p>
    </section>
    """
  end

  defp server(assigns), do: ~H""

  attr :state, :map, required: true
  attr :snapshots, :map, required: true
  attr :server?, :boolean, required: true

  defp recovery(assigns) do
    assigns =
      assign(assigns,
        card: @card,
        id: if(assigns.server?, do: "always-on-server-recovery", else: "always-on-recovery"),
        heading: if(assigns.server?, do: "The server's recovery", else: "Recovery"),
        moving_back: if(assigns.server?, do: @moving_back_here, else: @moving_back)
      )

    ~H"""
    <section id={@id} class={[@card, "space-y-4"]}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold">{@heading}</h3>
          <p id="always-on-snapshots-sentence" class="mt-0.5 text-sm text-base-content/70">
            {@snapshots["sentence"]}
          </p>
          <p id="always-on-passphrase-state" class="text-xs text-base-content/60">
            {if @snapshots["recipient_set"],
              do: "A recovery passphrase is set.",
              else: "No recovery passphrase is set."}
          </p>
        </div>
        <button
          :if={@snapshots["configured"]}
          id="always-on-backup"
          type="button"
          class="btn btn-sm btn-primary shrink-0"
          phx-click="always_on_backup"
        >
          Back up now
        </button>
      </div>
      <.notice notices={@state.notices} area={:recovery} />
      <ul class="space-y-2">
        <.target :for={target <- @snapshots["targets"]} target={target} zone={@state.zone} />
      </ul>
      <p id="always-on-moving-back" class="text-xs leading-5 text-base-content/60">
        {@moving_back}
      </p>
      <%= unless @server? do %>
        <.passphrase_form state={@state} set?={@snapshots["recipient_set"]} />
        <.storage_form state={@state} />
      <% end %>
    </section>
    """
  end

  attr :target, :map, required: true
  attr :zone, :string, default: nil

  defp target(assigns) do
    assigns = assign(assigns, verified: assigns.target["last_verified"])

    ~H"""
    <li id={"always-on-target-#{@target["id"]}"} class="rounded-field border border-base-300 p-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="text-sm font-medium">{@target["label"]}</span>
        <span :if={!@target["configured"]} class="badge badge-sm badge-ghost">Off</span>
        <span :if={@target["waiting"]} class="badge badge-sm badge-ghost">Waiting</span>
        <code :if={@target["destination"]} class="font-mono text-xs text-base-content/60">
          {@target["destination"]}
        </code>
      </div>
      <p :if={@verified} class="mt-1 text-xs text-base-content/70">
        Last verified {clock(@verified["at"], @zone)}: {@verified["name"]}
        <span :if={@verified["key_id"]}>(recovery key {@verified["key_id"]})</span>
      </p>
      <p :if={@target["configured"] && !@verified} class="mt-1 text-xs text-base-content/60">
        Nothing verified here yet.
      </p>
      <p :if={@target["waiting"]} class="mt-1 text-xs text-base-content/70">
        {@target["waiting"]}
      </p>
      <p :if={@target["last_error"]} class="mt-1 text-xs text-error">{@target["last_error"]}</p>
    </li>
    """
  end

  attr :state, :map, required: true
  attr :set?, :boolean, required: true

  # Two password fields, never given a value; the form's id carries the
  # generation, so a submission replaces it and the browser clears both.
  defp passphrase_form(assigns) do
    ~H"""
    <form
      id={"always-on-passphrase-#{@state.form_gen}"}
      phx-submit="always_on_passphrase"
      class="space-y-2 border-t border-base-300 pt-4"
      autocomplete="off"
    >
      <p class="text-sm font-medium">
        {if @set?, do: "Change the recovery passphrase", else: "Set the recovery passphrase"}
      </p>
      <p class="text-xs text-base-content/60">
        At least 12 characters. Snapshots are encrypted to a key made from it, and only the
        passphrase opens them; Fermix never stores it.
      </p>
      <p :if={@set?} id="always-on-passphrase-change" class="text-xs text-base-content/60">
        Snapshots written before a change keep opening only with the passphrase they were
        written for.
      </p>
      <div class="grid gap-2 @md:grid-cols-2">
        <.password_pair name="always_on_passphrase" />
      </div>
      <div class="flex items-center justify-between gap-2">
        <.notice notices={@state.notices} area={:passphrase} />
        <button type="submit" class="btn btn-sm ml-auto">Save passphrase</button>
      </div>
    </form>
    """
  end

  attr :name, :string, required: true

  defp password_pair(assigns) do
    ~H"""
    <input
      type="password"
      name={"#{@name}[password]"}
      value=""
      autocomplete="new-password"
      aria-label="Recovery passphrase"
      placeholder="Recovery passphrase"
      class="input input-sm input-bordered w-full"
    />
    <input
      type="password"
      name={"#{@name}[password_again]"}
      value=""
      autocomplete="new-password"
      aria-label="Type it again"
      placeholder="Type it again"
      class="input input-sm input-bordered w-full"
    />
    """
  end

  attr :state, :map, required: true

  defp storage_form(%{state: %{storage: {:error, sentence}}} = assigns) do
    assigns = assign(assigns, sentence: sentence)

    ~H"""
    <p class="text-xs text-error">{@sentence}</p>
    """
  end

  defp storage_form(assigns) do
    rows = rows(assigns.state.storage)
    fields = Enum.filter(rows, &storage_row?/1)

    assigns =
      assign(assigns,
        plain: Enum.reject(fields, & &1["advanced"]),
        advanced: Enum.filter(fields, & &1["advanced"]),
        secrets: Enum.filter(rows, &(&1["kind"] == "secret"))
      )

    ~H"""
    <form
      id="always-on-storage"
      phx-submit="always_on_storage"
      class="space-y-3 border-t border-base-300 pt-4"
    >
      <p class="text-sm font-medium">Where snapshots are kept</p>
      <div class="grid gap-3 @md:grid-cols-2">
        <.field :for={row <- @plain} row={row} />
      </div>
      <details :if={@advanced != []} id="always-on-storage-advanced" class="group">
        <summary class="cursor-pointer text-sm text-base-content/70">Advanced</summary>
        <div class="mt-2 grid gap-3 @md:grid-cols-2">
          <.field :for={row <- @advanced} row={row} />
        </div>
      </details>
      <div class="flex items-center justify-between gap-2">
        <.notice notices={@state.notices} area={:storage} />
        <button type="submit" class="btn btn-sm ml-auto">Save</button>
      </div>
    </form>
    <form
      :if={@secrets != []}
      id={"always-on-keys-#{@state.form_gen}"}
      phx-submit="always_on_keys"
      class="space-y-3 border-t border-base-300 pt-4"
      autocomplete="off"
    >
      <p class="text-sm font-medium">Access key</p>
      <p class="text-xs text-base-content/60">
        Only for signing in with an access key. Leave a field empty to keep what is stored.
      </p>
      <div class="grid gap-3 @md:grid-cols-2">
        <.secret_field :for={row <- @secrets} row={row} />
      </div>
      <div class="flex items-center justify-between gap-2">
        <.notice notices={@state.notices} area={:keys} />
        <button type="submit" class="btn btn-sm ml-auto">Store keys</button>
      </div>
    </form>
    """
  end

  attr :row, :map, required: true

  defp field(%{row: %{"kind" => "choice"}} = assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-xs font-medium">{@row["label"]}</span>
      <select
        name={"always_on_storage[#{@row["key"]}]"}
        class="select select-sm select-bordered w-full"
      >
        <option
          :for={option <- @row["options"]}
          value={option["value"]}
          selected={option["value"] == @row["value"]}
          disabled={option["disabled"]}
        >
          {option["label"]}
        </option>
      </select>
      <span :if={@row["info"]} class="mt-1 block text-xs leading-5 text-base-content/60">
        {@row["info"]}
      </span>
    </label>
    """
  end

  defp field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-xs font-medium">{@row["label"]}</span>
      <input
        type={if @row["kind"] == "number", do: "number", else: "text"}
        name={"always_on_storage[#{@row["key"]}]"}
        value={@row["value"]}
        min={@row["min"]}
        max={@row["max"]}
        placeholder={@row["example"]}
        class="input input-sm input-bordered w-full"
      />
      <span :if={@row["footer"]} class="mt-1 block text-xs leading-5 text-base-content/60">
        {@row["footer"]}
      </span>
    </label>
    """
  end

  attr :row, :map, required: true

  defp secret_field(assigns) do
    ~H"""
    <label class="form-control w-full">
      <span class="label pb-1 text-xs font-medium">{@row["label"]}</span>
      <input
        type="password"
        name={"secret[#{@row["key"]}]"}
        value=""
        autocomplete="off"
        placeholder={if @row["present"], do: "Stored", else: "Not set"}
        class="input input-sm input-bordered w-full font-mono"
      />
    </label>
    """
  end

  attr :state, :map, required: true
  attr :enrollment, :map, default: nil
  attr :replacing?, :boolean, required: true

  defp enrollment(assigns) do
    assigns =
      assign(assigns,
        card: @card,
        existing_host: @existing_host_command,
        heading: if(assigns.replacing?, do: "Replace the server", else: "Move to a server"),
        facts: if(assigns.replacing?, do: @replacing, else: @before_moving)
      )

    ~H"""
    <section id="always-on-enrollment" class={[@card, "space-y-4"]}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h3 class="text-sm font-semibold">{@heading}</h3>
          <p id="always-on-enrollment-state" class="mt-0.5 text-sm text-base-content/70">
            {enrollment_sentence(@enrollment, @state.zone)}
          </p>
        </div>
        <button
          id="always-on-enroll"
          type="button"
          class="btn btn-sm btn-primary shrink-0"
          phx-click="always_on_enroll"
        >
          {enroll_label(@enrollment)}
        </button>
      </div>
      <.notice notices={@state.notices} area={:enrollment} />
      <.code :if={@state.code} code={@state.code} zone={@state.zone} />
      <.route existing_host={@existing_host} />
      <div id="always-on-before-moving" class="space-y-1 rounded-field border border-base-300 p-3">
        <p class="text-sm font-medium">Before you move</p>
        <ul class="list-disc space-y-1 pl-4 text-xs leading-5 text-base-content/70">
          <li :for={fact <- @facts}>{fact}</li>
        </ul>
      </div>
    </section>
    """
  end

  attr :existing_host, :string, required: true

  # The way to a server: the command for a host of your own.
  defp route(assigns) do
    ~H"""
    <div class="space-y-1 rounded-field border border-base-300 p-3">
      <p class="text-sm font-medium">On a Linux server you have</p>
      <p class="text-xs leading-5 text-base-content/70">
        Run this on the server as an account that can use sudo. It asks for the code
        without showing it.
      </p>
      <.copy_block id="always-on-existing-host" text={@existing_host} label="Copy" />
    </div>
    """
  end

  defp enrollment_sentence(nil, _zone), do: "No code is open. A code works once, for 30 minutes."

  defp enrollment_sentence(%{"state" => "open", "expires_at" => at}, zone),
    do: "A code is open until #{clock(at, zone)}; Fermix is waiting for the server to use it."

  defp enrollment_sentence(%{"state" => "used"}, _zone),
    do: "The last code was used. The server it enrolled is listed below."

  defp enrollment_sentence(%{"state" => "expired"}, _zone),
    do: "The last code expired unused. Get a new one when the server is ready."

  # One code is open at a time: a new one stops the open one working.
  defp enroll_label(%{"state" => "open"}), do: "Get a new code (the open one stops working)"
  defp enroll_label(_enrollment), do: "Get a code"

  attr :code, :map, required: true
  attr :zone, :string, default: nil

  defp code(assigns) do
    ~H"""
    <div id="always-on-code" class="space-y-2 rounded-box border border-primary/30 bg-primary/5 p-4">
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="text-sm font-semibold">Enrollment code</p>
          <p class="text-xs text-base-content/60">
            Shown once. It works once, until {clock(@code.expires_at, @zone)}.
          </p>
        </div>
        <button type="button" class="btn btn-ghost btn-xs" phx-click="always_on_code_done">
          Done
        </button>
      </div>
      <.copy_block id="always-on-code-value" text={@code.code} label="Copy code" />
    </div>
    """
  end

  attr :state, :map, required: true
  attr :candidates, :list, required: true
  attr :replacing?, :boolean, required: true

  defp candidates(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <section id="always-on-candidates" class={[@card, "space-y-3"]}>
      <h3 class="text-sm font-semibold">Servers waiting for the move</h3>
      <p :if={@candidates == []} class="text-sm text-base-content/70">
        None yet. Get a code above, then start the server with it.
      </p>
      <.notice notices={@state.notices} area={:candidates} />
      <.notice notices={@state.notices} area={:replace} />
      <.candidate
        :for={candidate <- @candidates}
        candidate={candidate}
        state={@state}
        replacing?={@replacing?}
      />
    </section>
    """
  end

  attr :candidate, :map, required: true
  attr :state, :map, required: true
  attr :replacing?, :boolean, required: true

  defp candidate(assigns) do
    assigns =
      assign(assigns,
        id: assigns.candidate["candidate_id"],
        instance: assigns.candidate["instance"],
        review: review_for(assigns.state, assigns.candidate["candidate_id"])
      )

    ~H"""
    <article
      id={"always-on-candidate-#{@id}"}
      class="space-y-2 rounded-field border border-base-300 p-3"
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="text-sm font-medium">{@candidate["name"]}</span>
        <span class="text-xs text-base-content/60">
          {@candidate["os"]} · {@candidate["arch"]} · Fermix {@candidate["version"]}
        </span>
      </div>
      <p class="text-xs text-base-content/60">
        Enrolled {clock(@candidate["enrolled_at"], @state.zone)}; waits until {clock(
          @candidate["expires_at"],
          @state.zone
        )}.
      </p>
      <.instance :if={@instance} instance={@instance} />
      <button
        :if={!@review}
        id={"always-on-review-#{@id}"}
        type="button"
        class="btn btn-sm"
        phx-click="always_on_review"
        phx-value-candidate={@id}
      >
        Review the move
      </button>
      <.review :if={@review} review={@review} />
      <.move_command :if={@review && @review.ready && !@replacing?} id={@id} />
      <.replace_form
        :if={@review && @review.ready && @replacing?}
        candidate={@candidate}
        state={@state}
      />
    </article>
    """
  end

  attr :instance, :map, required: true

  # What the host said of itself, which nobody verified.
  defp instance(assigns) do
    assigns = assign(assigns, unverified: @unverified_sentence)

    ~H"""
    <div class="space-y-1">
      <div class="flex items-center gap-2">
        <span class="badge badge-sm badge-warning">Unverified</span>
        <span class="text-xs text-base-content/70">{@unverified}</span>
      </div>
      <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 text-xs">
        <dt class="text-base-content/60">Instance</dt>
        <dd class="font-mono">{@instance["instance_id"]}</dd>
        <dt class="text-base-content/60">Provider</dt>
        <dd>{@instance["provider"]}</dd>
        <dt class="text-base-content/60">Region</dt>
        <dd>{@instance["region"]}</dd>
        <dt :if={@instance["account_id"]} class="text-base-content/60">Account</dt>
        <dd :if={@instance["account_id"]} class="font-mono">{@instance["account_id"]}</dd>
      </dl>
    </div>
    """
  end

  attr :review, :map, required: true

  # What the owner reviews before the move: each item as the daemon said it,
  # and a block shown as one.
  defp review(assigns) do
    ~H"""
    <div
      id={"always-on-readiness-#{@review.candidate_id}"}
      class="space-y-2 border-t border-base-300 pt-3"
    >
      <div class="flex items-center justify-between gap-2">
        <p class="text-sm font-medium">Before the move</p>
        <button type="button" class="btn btn-ghost btn-xs" phx-click="always_on_review_done">
          Done
        </button>
      </div>
      <p
        :if={!@review.ready}
        id={"always-on-readiness-#{@review.candidate_id}-blocked"}
        class="text-sm text-error"
        role="alert"
      >
        The move cannot start while anything below blocks it.
      </p>
      <ul class="space-y-1.5">
        <li
          :for={item <- @review.items}
          id={"always-on-readiness-#{@review.candidate_id}-#{item["id"]}"}
          class="flex items-start gap-2 text-xs leading-5"
        >
          <span class={["badge badge-sm shrink-0", status_badge(item["status"])]}>
            {status_label(item["status"])}
          </span>
          <span class={[item["status"] == "block" && "text-error"]}>{item["sentence"]}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp status_badge("ok"), do: "badge-success"
  defp status_badge("warn"), do: "badge-warning"
  defp status_badge("block"), do: "badge-error"

  defp status_label("ok"), do: "Ready"
  defp status_label("warn"), do: "Note"
  defp status_label("block"), do: "Blocks"

  attr :id, :string, required: true

  # On the primary the move is its command (the moduledoc says why). A
  # server that is itself the primary, being replaced, keeps no desktop of the
  # new one: `--retire`, which the owner adds, since only they know.
  defp move_command(assigns) do
    assigns = assign(assigns, command: move_command_text(assigns.id))

    ~H"""
    <div class="space-y-2">
      <p class="text-xs leading-5 text-base-content/70">
        To move, run this on this computer. Moving restarts Fermix here as a desktop of the
        server, so this page goes away while it restarts. Leave out the flag and Fermix asks
        for the recovery passphrase twice without showing it.
      </p>
      <.copy_block id={"always-on-move-#{@id}"} text={@command} label="Copy command" />
      <p id={"always-on-move-retire-#{@id}"} class="text-xs leading-5 text-base-content/70">
        If this computer is a server you are replacing, add --retire to the command: Fermix
        here hands the home over and then serves nothing, instead of staying a desktop of the
        new server. Leave it out on a computer you keep using.
      </p>
    </div>
    """
  end

  defp move_command_text(candidate_id),
    do: "fermix home move --to #{candidate_id} --recovery-passphrase-file FILE"

  attr :candidate, :map, required: true
  attr :state, :map, required: true

  # From a linked desktop the move runs on the server it replaces, which keeps
  # no desktop of its own; this computer does not restart.
  defp replace_form(assigns) do
    ~H"""
    <form
      id={"always-on-replace-#{@state.form_gen}"}
      phx-submit="always_on_replace"
      class="space-y-2 border-t border-base-300 pt-3"
      autocomplete="off"
    >
      <input type="hidden" name="always_on_replace[candidate]" value={@candidate["candidate_id"]} />
      <p class="text-xs leading-5 text-base-content/70">
        Moving restarts the server, which hands this home to {@candidate["name"]} and then
        serves nothing; this computer follows the home there. Type the recovery passphrase
        twice: the snapshots {@candidate["name"]} writes open only with it.
      </p>
      <div class="grid gap-2 @md:grid-cols-2">
        <.password_pair name="always_on_replace" />
      </div>
      <button type="submit" class="btn btn-sm btn-primary">
        Move to {@candidate["name"]}
      </button>
    </form>
    """
  end

  attr :state, :map, required: true
  attr :desktops, :list, required: true

  defp desktops(assigns) do
    assigns = assign(assigns, card: @card)

    ~H"""
    <section :if={@desktops != []} id="always-on-desktops" class={[@card, "space-y-3"]}>
      <h3 class="text-sm font-semibold">Desktops</h3>
      <div
        :for={desktop <- @desktops}
        id={"always-on-desktop-#{desktop["device_id"]}"}
        class="flex items-center justify-between gap-3"
      >
        <div class="min-w-0">
          <p class="text-sm font-medium">{desktop["name"]}</p>
          <.dot
            :if={desktop["connected"]}
            tone="bg-success"
            text={"Connected since #{clock(desktop["since"], @state.zone)}"}
          />
          <.dot :if={!desktop["connected"]} tone="bg-base-content/30" text="Not connected" />
        </div>
      </div>
    </section>
    """
  end

  attr :notices, :map, required: true
  attr :area, :atom, required: true

  defp notice(%{notices: notices, area: area} = assigns) when is_map_key(notices, area) do
    {tone, text} = Map.fetch!(notices, area)
    assigns = assign(assigns, tone: tone, text: text)

    ~H"""
    <p
      id={"always-on-notice-#{@area}"}
      class={["text-xs", if(@tone == :error, do: "text-error", else: "text-base-content/70")]}
      role={if @tone == :error, do: "alert", else: "status"}
    >
      {@text}
    </p>
    """
  end

  defp notice(assigns), do: ~H""

  attr :tone, :string, required: true
  attr :text, :string, required: true

  defp dot(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 text-xs text-base-content/70">
      <span class={["size-1.5 shrink-0 rounded-full", @tone]} />{@text}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, required: true

  defp copy_block(assigns) do
    ~H"""
    <div class="flex items-start gap-2">
      <code
        id={@id}
        class="min-w-0 flex-1 select-all break-all rounded-field bg-base-200 px-2 py-1.5 font-mono text-xs"
      >
        {@text}
      </code>
      <button
        id={"#{@id}-copy"}
        type="button"
        class="btn btn-ghost btn-xs shrink-0"
        phx-hook="CopyText"
        data-copy-from={@id}
      >
        {@label}
      </button>
    </div>
    """
  end
end
