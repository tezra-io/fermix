defmodule FermixCore.Native.Notifications.MacApp do
  @moduledoc """
  Notifications on a Mac (M76 §4.4, §4.6): posted by the Fermix app, asked
  over the native host wire (`NativeHost.Link`), under the app's own
  identity, so the prompt names Fermix and the grant survives every engine
  release.

  Both questions start from the app attached on the wire
  (`Native.HostAvailability`). An app that is not attached is opened through
  `AppLauncher` once and waited for under its deadline, with no setting: a
  reminder stored for this Mac has nowhere else to ring, and storing it was the
  owner's consent. A launch that never attached is not repeated within the
  cooldown after it. Each wait is bounded by the clock and by a poll count, so
  a clock that stops cannot hold a caller.

    * `ready/2` asks for the grant. A turn from this computer's own surfaces
      (`Native.local_surface?/1`) sends `notifications.authorize`, which may
      raise the macOS prompt, and waits for it under a bound of its own: a
      prompt still open at the bound refuses, and the person's answer arrives
      later as `capabilities`. Every other turn sends `host.status` and never
      prompts. Each refusal is the sentence that says where to grant.
    * `post/2` sends `notifications.post`, which never prompts: the title, the
      body, the sound, and for a reminder its id with the one action, Snooze
      10 minutes. Its answer is a reason from `Native.Notifications`' closed
      set.

  No backend stands in for a missing grant: a withheld grant is the owner's
  answer, and the refusal names where to change it.

  Seams: `:host_availability` (the record to read), `:launcher`
  (`(timeout_ms -> :ok | {:error, String.t()})`), `:now` (a millisecond
  clock), `:sleep`, and `:request`, the fake link
  (`(link, type, payload, timeout_ms -> NativeHost.Link.answer())`); each
  defaults to the real one.
  """

  @behaviour FermixCore.Native.Notifications

  require Logger

  alias FermixCore.AppLauncher
  alias FermixCore.Native
  alias FermixCore.Native.HostAvailability
  alias FermixCore.Native.Notifications
  alias FermixCore.NativeHost.Link
  alias FermixCore.NativeHost.Protocol

  @poll_ms 100
  @request_timeout_ms 5_000
  # Long enough for a person at the Mac to read and answer the prompt.
  @authorize_timeout_ms 30_000

  # Each refusal is a clause, as `Native.Notifications`' `ready/2` callback
  # asks: its caller embeds it ("… because <refusal>.").
  @needs "Fermix needs permission to show notifications on your Mac"
  @not_allowed "Fermix is not allowed to show notifications on your Mac"
  @grant "open Settings > Permissions > Notifications > Grant…"
  @allow "open System Settings > Notifications > Fermix and turn on Allow notifications"
  @not_opened "the Fermix app on this Mac could not be opened"

  @doc """
  Whether a notification could be shown now: the app attached (opened if it
  is not) and the grant held, asked with a prompt only for a turn from this
  computer's own surfaces.
  """
  @impl true
  @spec ready(map(), keyword()) :: :ok | {:error, String.t()}
  def ready(context, opts) when is_map(context) and is_list(opts) do
    case host(opts) do
      {:ok, link} -> ask_grant(link, Native.local_surface?(context), opts)
      {:error, reason} -> {:error, host_sentence(reason)}
    end
  end

  @doc "Shows one notification through the app, answering its id or a reason."
  @impl true
  @spec post(Notifications.notification(), keyword()) ::
          {:ok, Notifications.id()} | {:error, Notifications.reason()}
  def post(%{title: title, body: body, sound: sound} = notification, opts)
      when is_binary(title) and title != "" and is_binary(body) and is_boolean(sound) and
             is_list(opts) do
    case host(opts) do
      {:ok, link} ->
        link
        |> request(opts).("notifications.post", post_payload(notification), @request_timeout_ms)
        |> posted()

      {:error, reason} ->
        Logger.warning("no notification posted: #{host_sentence(reason)}")
        {:error, :host_unavailable}
    end
  end

  # ── the grant ──────────────────────────────────────────────────────────────

  defp ask_grant(link, true = _here, opts) do
    link
    |> request(opts).("notifications.authorize", %{}, @authorize_timeout_ms)
    |> granted(:here)
  end

  defp ask_grant(link, false = _here, opts) do
    link
    |> request(opts).("host.status", %{}, @request_timeout_ms)
    |> granted(:away)
  end

  defp granted({:ok, %{"state" => state}}, :here), do: grant(state, :here)
  defp granted({:ok, %{"notifications" => state}}, :away), do: grant(state, :away)

  defp granted({:error, :timeout}, :here),
    do: {:error, "#{@needs}; answer the macOS prompt that is open now, then ask again"}

  defp granted({:error, :timeout}, :away),
    do: {:error, "the Fermix app on this Mac did not answer in time"}

  defp granted({:error, :closed}, _where),
    do: {:error, "the Fermix app on this Mac went away before it answered"}

  defp granted({:error, %{"message" => message}}, _where),
    do: {:error, "the Fermix app on this Mac could not answer: #{message}"}

  defp grant("granted", _where), do: :ok
  defp grant("not_asked", :here), do: {:error, "#{@needs}; #{@grant}"}
  defp grant("not_asked", :away), do: {:error, "#{@needs}; next time you are at it, #{@grant}"}
  defp grant("not_granted", :here), do: {:error, "#{@not_allowed}; #{@allow}"}

  defp grant("not_granted", :away),
    do: {:error, "#{@not_allowed}; next time you are at it, #{@allow}"}

  # ── the post ───────────────────────────────────────────────────────────────

  defp post_payload(%{title: title, body: body, sound: sound} = notification) do
    base = %{"title" => title, "body" => body, "sound" => sound}

    case Map.get(notification, :reminder_id) do
      nil ->
        Map.put(base, "actions", [])

      id when is_binary(id) ->
        Map.merge(base, %{"reminder_id" => id, "actions" => Protocol.reminder_actions()})
    end
  end

  defp posted({:ok, %{"notification_id" => id}}), do: {:ok, id}
  defp posted({:error, %{"reason" => "not_authorized"}}), do: {:error, :not_authorized}

  defp posted({:error, %{"reason" => "post_failed", "message" => words}}),
    do: {:error, {:failed, words}}

  defp posted({:error, %{"reason" => "host_unavailable"}}), do: {:error, :host_unavailable}

  defp posted({:error, %{"reason" => reason, "message" => message}}),
    do: {:error, {:failed, "#{reason}: #{message}"}}

  defp posted({:error, :timeout}), do: {:error, :timeout}
  defp posted({:error, :closed}), do: {:error, :host_unavailable}

  # ── the app, attached or opened ────────────────────────────────────────────

  defp host_sentence(:not_served),
    do: "the Fermix app on this Mac could not be reached: nothing in this engine serves it"

  defp host_sentence(:stopping), do: "the Fermix app on this Mac is quitting"
  defp host_sentence(:not_attached), do: "the Fermix app on this Mac did not connect in time"
  defp host_sentence({:launch_failed, reason}), do: "#{@not_opened}: #{reason}"

  defp request(opts), do: Keyword.get(opts, :request, &Link.request/4)

  defp host(opts) do
    record = Keyword.get(opts, :host_availability, HostAvailability)

    deps = %{
      claim: fn clock, until_ms -> HostAvailability.claim(record, clock, until_ms) end,
      launching: fn until_ms -> HostAvailability.launching(record, until_ms) end,
      launcher: Keyword.get(opts, :launcher, &AppLauncher.launch/1),
      now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      cooldown_ms: AppLauncher.cooldown_ms()
    }

    deadline = deps.now.() + AppLauncher.deadline_ms()
    run(deps, deadline, div(AppLauncher.deadline_ms(), @poll_ms) + 1)
  end

  # A spent poll count reads as a spent deadline, so the wait ends on the same
  # answer whichever bound ran out first. A caller that finds a launch pending
  # waits on that launch's deadline, never past its own. The step is claimed
  # (`HostAvailability.claim/3`): a launch it answers is already recorded, so
  # a second caller waits on it instead of opening the app again.
  defp run(deps, deadline, polls) do
    now = deps.now.()
    remaining = if polls > 0, do: deadline - now, else: 0
    clock = %{now_ms: now, remaining_ms: remaining, cooldown_ms: deps.cooldown_ms}

    case deps.claim.(clock, deadline) do
      {:attached, link} -> {:ok, link}
      :launch -> launch(deps, deadline, polls, now)
      {:wait, until_ms} -> wait(deps, min(deadline, until_ms), polls, now)
      {:unavailable, reason} -> {:error, reason}
    end
  end

  # A launch counts as a poll, so an app that attaches and dies at once, which
  # voids the launch, is opened again only while the bounds allow. A launch
  # that fails at once ends there, and its cooldown starts from that moment.
  defp launch(deps, deadline, polls, now) do
    case deps.launcher.(max(deadline - now, 1)) do
      :ok ->
        run(deps, deadline, polls - 1)

      {:error, reason} when is_binary(reason) ->
        :ok = deps.launching.(deps.now.())
        {:error, {:launch_failed, reason}}
    end
  end

  defp wait(deps, deadline, polls, now) do
    deps.sleep.(min(@poll_ms, max(deadline - now, 0)))
    run(deps, deadline, polls - 1)
  end
end
