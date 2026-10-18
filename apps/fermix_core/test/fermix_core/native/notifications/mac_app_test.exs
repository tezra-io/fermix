defmodule FermixCore.Native.Notifications.MacAppTest do
  @moduledoc """
  The Mac notification backend (M76 §4.4, §4.6, D5, D13) against a record of
  its own and a fake link: which request each surface sends, the sentence each
  grant state refuses with, the launch on demand with its deadline and
  cooldown, and every answer a post can get. Nothing opens the app or a
  socket: the launcher, the clock and the link are the test's.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias FermixCore.AppLauncher
  alias FermixCore.Native.HostAvailability
  alias FermixCore.Native.Notifications.MacApp

  @here %{channel: "companion", computer_use_origin: :interactive}
  @away %{channel: "telegram", computer_use_origin: :interactive}
  @notification %{title: "Tea", body: "Tea, today at 16:05.", sound: true, reminder_id: "rem_1"}
  @snooze %{"id" => "snooze_10m", "title" => "Snooze 10 minutes"}

  @not_asked_away "Fermix needs permission to show notifications on your Mac; next time you " <>
                    "are at it, open Settings > Permissions > Notifications > Grant…"
  @not_granted_away "Fermix is not allowed to show notifications on your Mac; next time you " <>
                      "are at it, open System Settings > Notifications > Fermix and turn on " <>
                      "Allow notifications"
  @not_opened "the Fermix app on this Mac could not be opened"

  defp process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp record do
    host = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    :ok = HostAvailability.listening(host, process())
    host
  end

  defp attached do
    host = record()
    link = process()
    :ok = HostAvailability.attached(host, link, 1, "0.6.0")
    {host, link}
  end

  # A link that records each request and answers from `answers`, keyed by type.
  defp link_answering(link, answers) do
    test = self()

    fn ^link, type, payload, timeout_ms ->
      send(test, {:request, type, payload, timeout_ms})
      Map.fetch!(answers, type)
    end
  end

  defp no_launch, do: fn _timeout_ms -> flunk("the app was opened") end
  defp no_request, do: fn _link, type, _payload, _timeout -> flunk("#{type} was sent") end

  # A clock that moves `step_ms` every time it is read, from `start_ms`.
  defp clock(start_ms, step_ms) do
    agent = start_supervised!({Agent, fn -> start_ms end}, id: make_ref())
    fn -> Agent.get_and_update(agent, &{&1, &1 + step_ms}) end
  end

  defp opts(host, request, overrides \\ []) do
    Keyword.merge(
      [
        host_availability: host,
        request: request,
        launcher: no_launch(),
        now: clock(0, 0),
        sleep: fn _ms -> :ok end
      ],
      overrides
    )
  end

  defp status(notifications),
    do: {:ok, %{"host_version" => "0.6.0", "notifications" => notifications}}

  describe "ready/2 from away" do
    test "asks host.status, never the prompt, and a granted app is ready" do
      {host, link} = attached()
      request = link_answering(link, %{"host.status" => status("granted")})

      assert MacApp.ready(@away, opts(host, request)) == :ok
      assert_received {:request, "host.status", %{}, 5_000}
      refute_received {:request, "notifications.authorize", _payload, _timeout}
    end

    test "a grant not yet asked for, or refused, says where to grant it, and prompts nothing" do
      {host, link} = attached()

      for {state, sentence} <- [
            {"not_asked", @not_asked_away},
            {"not_granted", @not_granted_away}
          ] do
        request = link_answering(link, %{"host.status" => status(state)})
        assert MacApp.ready(@away, opts(host, request)) == {:error, sentence}
      end

      refute_received {:request, "notifications.authorize", _payload, _timeout}
    end
  end

  describe "ready/2 from this computer's own surfaces" do
    test "asks notifications.authorize, bounded, and a granted answer is ready" do
      {host, link} = attached()

      request =
        link_answering(link, %{"notifications.authorize" => {:ok, %{"state" => "granted"}}})

      for here <- [@here, %{channel: "voice", computer_use_origin: :voice}] do
        assert MacApp.ready(here, opts(host, request)) == :ok
        assert_received {:request, "notifications.authorize", %{}, 30_000}
      end

      refute_received {:request, "host.status", _payload, _timeout}
    end

    test "a refused or unasked grant says where to grant it, to a person who is here" do
      {host, link} = attached()

      for {state, sentence} <- [
            {"not_granted",
             "Fermix is not allowed to show notifications on your Mac; open System Settings " <>
               "> Notifications > Fermix and turn on Allow notifications"},
            {"not_asked",
             "Fermix needs permission to show notifications on your Mac; open Settings > " <>
               "Permissions > Notifications > Grant…"}
          ] do
        answers = %{"notifications.authorize" => {:ok, %{"state" => state}}}

        assert MacApp.ready(@here, opts(host, link_answering(link, answers))) ==
                 {:error, sentence}
      end
    end

    test "a prompt still open at the deadline refuses, and leaves the prompt to the person" do
      {host, link} = attached()
      request = link_answering(link, %{"notifications.authorize" => {:error, :timeout}})

      assert MacApp.ready(@here, opts(host, request)) ==
               {:error,
                "Fermix needs permission to show notifications on your Mac; answer the macOS " <>
                  "prompt that is open now, then ask again"}
    end
  end

  describe "the app, opened on demand" do
    test "an app that is not attached is opened once, waited for, then asked" do
      host = record()
      link = process()
      test = self()

      launcher = fn timeout_ms ->
        send(test, {:launched, timeout_ms})
        :ok = HostAvailability.attached(host, link, 1, "0.6.0")
      end

      request = link_answering(link, %{"host.status" => status("granted")})

      assert MacApp.ready(@away, opts(host, request, launcher: launcher)) == :ok
      assert_received {:launched, timeout_ms}
      assert timeout_ms == AppLauncher.deadline_ms()
      refute_received {:launched, _again}
      assert_received {:request, "host.status", %{}, _timeout}
    end

    test "a launch that never attaches is not opened again within the cooldown" do
      host = record()
      test = self()
      launcher = fn _timeout_ms -> send(test, :launched) && :ok end
      ticking = [now: clock(0, 500), launcher: launcher]

      assert MacApp.ready(@away, opts(host, no_request(), ticking)) == {:error, @not_opened}
      assert_received :launched
      assert is_integer(HostAvailability.current(host).launch_until)

      # Every read of this clock is inside the cooldown after that deadline.
      again = [now: clock(AppLauncher.deadline_ms() + 1_000, 0), launcher: no_launch()]
      assert MacApp.ready(@away, opts(host, no_request(), again)) == {:error, @not_opened}

      assert MacApp.post(@notification, opts(host, no_request(), again)) ==
               {:error, :host_unavailable}
    end

    # Each launch whose app attaches and dies at once voids the launch, so the
    # next claim may launch again; the caller's own deadline and poll count
    # still end it, however often the app comes up and dies.
    test "an app that attaches and dies at once is opened again only within the deadline" do
      host = record()
      test = self()

      launcher = fn _timeout_ms ->
        send(test, :launched)
        link = process()
        :ok = HostAvailability.attached(host, link, 1, "0.6.0")
        ref = Process.monitor(link)
        Process.exit(link, :kill)
        assert_receive {:DOWN, ^ref, :process, ^link, :killed}
        await_detached(host)
      end

      ticking = [now: clock(0, 1_000), launcher: launcher]
      assert MacApp.ready(@away, opts(host, no_request(), ticking)) == {:error, @not_opened}

      launches = drain(:launched)
      assert launches in 1..3, "opened #{launches} times"
    end

    test "a launch that fails at once says why, and cools down from that moment" do
      host = record()
      launcher = fn _timeout_ms -> {:error, "open exited 1: no such app"} end

      assert MacApp.ready(@away, opts(host, no_request(), launcher: launcher)) ==
               {:error, @not_opened <> ": open exited 1: no such app"}

      assert HostAvailability.current(host).launch_until == 0
      assert MacApp.ready(@away, opts(host, no_request())) == {:error, @not_opened}
    end

    test "nothing serving the wire, or an app that is quitting, is refused without a launch" do
      empty = start_supervised!({HostAvailability, name: nil}, id: make_ref())

      assert MacApp.ready(@away, opts(empty, no_request())) ==
               {:error,
                "the Fermix app on this Mac could not be reached: nothing in this engine serves it"}

      {host, link} = attached()
      :ok = HostAvailability.stopping(host, link)

      assert MacApp.ready(@away, opts(host, no_request())) ==
               {:error, "the Fermix app on this Mac is quitting"}

      assert MacApp.post(@notification, opts(host, no_request())) == {:error, :host_unavailable}
    end
  end

  defp drain(message, count \\ 0) do
    receive do
      ^message -> drain(message, count + 1)
    after
      0 -> count
    end
  end

  # The record takes the link's exit as its own message, so the read is
  # repeated until it holds, bounded by a wall-clock deadline.
  defp await_detached(host, deadline_ms \\ 10_000) do
    until = System.monotonic_time(:millisecond) + deadline_ms
    await_detached_until(host, until)
  end

  defp await_detached_until(host, until) do
    cond do
      not HostAvailability.current(host).attached ->
        :ok

      System.monotonic_time(:millisecond) >= until ->
        flunk("the record never detached")

      true ->
        # sleep: one poll's interval, bounded by the deadline above
        Process.sleep(10)
        await_detached_until(host, until)
    end
  end

  describe "post/2" do
    test "one notifications.post with the reminder's id and its Snooze 10 minutes action" do
      {host, link} = attached()

      request =
        link_answering(link, %{"notifications.post" => {:ok, %{"notification_id" => "n-1"}}})

      assert MacApp.post(@notification, opts(host, request)) == {:ok, "n-1"}

      assert_received {:request, "notifications.post", payload, 5_000}

      assert payload == %{
               "reminder_id" => "rem_1",
               "title" => "Tea",
               "body" => "Tea, today at 16:05.",
               "sound" => true,
               "actions" => [@snooze]
             }

      refute_received {:request, _other, _payload, _timeout}
    end

    test "a notification for no reminder offers no action and names none" do
      {host, link} = attached()

      request =
        link_answering(link, %{"notifications.post" => {:ok, %{"notification_id" => "n-2"}}})

      for notification <- [
            Map.delete(@notification, :reminder_id),
            %{@notification | reminder_id: nil}
          ] do
        assert MacApp.post(notification, opts(host, request)) == {:ok, "n-2"}
        assert_received {:request, "notifications.post", payload, _timeout}
        assert payload["actions"] == []
        refute Map.has_key?(payload, "reminder_id")
      end
    end

    test "each answer lands in the closed set of reasons" do
      {host, link} = attached()

      rows = [
        {{:error, %{"reason" => "not_authorized", "message" => "off"}},
         {:error, :not_authorized}},
        {{:error,
          %{"reason" => "post_failed", "message" => "The notification could not be added"}},
         {:error, {:failed, "The notification could not be added"}}},
        {{:error, %{"reason" => "host_unavailable", "message" => "the app is quitting"}},
         {:error, :host_unavailable}},
        {{:error, %{"reason" => "invalid_request", "message" => "no title"}},
         {:error, {:failed, "invalid_request: no title"}}},
        {{:error, :timeout}, {:error, :timeout}},
        {{:error, :closed}, {:error, :host_unavailable}}
      ]

      for {answer, reason} <- rows do
        request = link_answering(link, %{"notifications.post" => answer})
        assert MacApp.post(@notification, opts(host, request)) == reason, inspect(answer)
      end
    end
  end
end
