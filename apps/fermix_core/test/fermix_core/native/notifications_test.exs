defmodule FermixCore.Native.NotificationsTest do
  @moduledoc """
  The notification service (M76 §4.3, §4.6): the backend each build resolves,
  the readiness and the post it delegates, and the delivery adapter the
  reminder rail resolves for platform `"computer"`, with every failure in
  `Delivery.Error`'s closed vocabulary. The D-Bus backend runs against a
  replayed `busctl`; nothing reads this machine.
  """

  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Delivery.Error
  alias FermixCore.Native.HostAvailability
  alias FermixCore.Native.Notifications
  alias FermixCore.Native.Notifications.DBus
  alias FermixCore.Native.Notifications.MacApp

  @busctl "/usr/bin/busctl"
  @brew_mac %{profile: :standalone_cli, os: :darwin}
  @mac_app %{profile: :app_engine, os: :darwin}
  @mac_checkout %{profile: :source, os: :darwin}
  @no_server "no desktop notification server is running on this machine"
  @text "Tea, today at 16:05."
  @notification %{title: "Tea", body: @text, sound: true}

  @brew_sentence "this build (the standalone Fermix, a Homebrew formula or a downloaded " <>
                   "binary) shows no notifications on this Mac; the Fermix app does, and " <>
                   "fermix migrate-to-app moves this install to it"

  defp scripted(answers) do
    test_pid = self()

    fn @busctl, args ->
      send(test_pid, {:busctl, args})
      member = Enum.find(["NameHasOwner", "Notify"], &(&1 in args))
      Map.fetch!(answers, member)
    end
  end

  # The D-Bus backend, named, against a scripted busctl.
  defp dbus(answers) do
    [
      placement: :here,
      provider: :dbus,
      runner: scripted(answers),
      find_executable: fn "busctl" -> @busctl end
    ]
  end

  defp server(notify_answer),
    do: dbus(%{"NameHasOwner" => {:ok, "b true\n"}, "Notify" => notify_answer})

  # The Mac app backend, named, on an attached app whose link answers a post
  # with `answer` and tells this test what it was sent.
  defp mac_app(answer) do
    record = start_supervised!({HostAvailability, name: nil}, id: make_ref())
    link = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(link, :kill) end)
    :ok = HostAvailability.listening(record, link)
    :ok = HostAvailability.attached(record, link, 1, "0.6.0")
    test_pid = self()

    request = fn ^link, "notifications.post", payload, _timeout_ms ->
      send(test_pid, {:posted, payload})
      answer
    end

    [placement: :here, provider: :mac_app, host_availability: record, request: request]
  end

  defp nothing_runs do
    [
      placement: :here,
      runner: fn _busctl, _args -> flunk("busctl ran") end,
      find_executable: fn "busctl" -> flunk("busctl was looked for") end
    ]
  end

  describe "resolve/1" do
    test "on every Linux build the host decides D-Bus" do
      for profile <- [:standalone_cli, :linux_package_cli, :source] do
        assert Notifications.resolve(host: %{profile: profile, os: :linux}, placement: :here) ==
                 {:ok, %{provider: :dbus, placement: :here, module: DBus, source: :build}}
      end
    end

    test "the Fermix app's own engine on a Mac decides the app" do
      assert Notifications.resolve(host: @mac_app, placement: :here) ==
               {:ok, %{provider: :mac_app, placement: :here, module: MacApp, source: :build}}
    end

    test "every host the provider table accepts resolves without raising" do
      hosts =
        [@mac_app, @brew_mac, @mac_checkout] ++
          for profile <- [:standalone_cli, :linux_package_cli, :source],
              do: %{profile: profile, os: :linux}

      for host <- hosts do
        assert {status, _resolution} = Notifications.resolve(host: host, placement: :here)
        assert status in [:ok, :error], inspect(host)
      end
    end

    test "a provider of none named against a host that offers one is refused at the seam" do
      for host <- [@mac_app, %{profile: :linux_package_cli, os: :linux}] do
        assert_raise ArgumentError, ~r/contradicts/, fn ->
          Notifications.resolve(provider: :none, host: host)
        end
      end
    end

    test "a named provider decides, and the resolution says so" do
      assert Notifications.resolve(provider: :dbus, host: @brew_mac, placement: :here) ==
               {:ok, %{provider: :dbus, placement: :here, module: DBus, source: :given}}
    end

    test "a build that offers none refuses, naming the build" do
      assert Notifications.resolve(host: @brew_mac) == {:error, @brew_sentence}

      assert Notifications.resolve(host: @mac_checkout) ==
               {:error,
                "this build (a development run from a source checkout) shows no " <>
                  "notifications on this Mac; the Fermix app's own engine does"}

      assert Notifications.resolve(provider: :none, host: @brew_mac) == {:error, @brew_sentence}
    end
  end

  describe "offered?/1" do
    test "a build offers notifications exactly where its provider is not none" do
      for host <- [@mac_app, %{profile: :linux_package_cli, os: :linux}] do
        assert Notifications.offered?(host: host), inspect(host)
      end

      for host <- [@brew_mac, @mac_checkout] do
        refute Notifications.offered?(host: host), inspect(host)
      end

      assert Notifications.offered?(provider: :dbus, host: @brew_mac)
      refute Notifications.offered?(provider: :none, host: @brew_mac)
    end
  end

  describe "refusal sentences" do
    # A caller embeds a refusal as a clause ("… because <sentence>."), so every
    # backend's refusal is one: no final period, and lowercase unless it starts
    # with "Fermix".
    test "every backend refuses in a clause" do
      for sentence <- refusals() do
        refute String.ends_with?(sentence, "."), "a sentence, not a clause: #{sentence}"

        first = String.first(sentence)

        assert String.starts_with?(sentence, "Fermix") or first == String.downcase(first),
               "a clause starts lowercase unless it starts with Fermix: #{sentence}"
      end
    end

    defp refusals do
      not_offered = for host <- [@brew_mac, @mac_checkout], do: refusal(host: host)

      dbus =
        for answer <- [
              {:ok, "b false\n"},
              {:error, :timeout},
              {:ok, ~s(s "yes"\n)},
              {:error, {:helper_failed, 1, "Failed to connect to bus: No such file or directory"}}
            ],
            do: refusal(dbus(%{"NameHasOwner" => answer}))

      missing =
        refusal(placement: :here, provider: :dbus, find_executable: fn "busctl" -> nil end)

      not_offered ++ dbus ++ [missing] ++ mac_app_refusals()
    end

    defp mac_app_refusals do
      here = %{channel: "companion", computer_use_origin: :interactive}
      away = %{channel: "telegram", computer_use_origin: :interactive}
      status = fn state -> {:ok, %{"host_version" => "0.6.0", "notifications" => state}} end

      answered =
        for {context, type, answer} <- [
              {away, "host.status", status.("not_asked")},
              {away, "host.status", status.("not_granted")},
              {here, "notifications.authorize", {:ok, %{"state" => "not_asked"}}},
              {here, "notifications.authorize", {:ok, %{"state" => "not_granted"}}},
              {here, "notifications.authorize", {:error, :timeout}},
              {away, "host.status", {:error, :timeout}},
              {away, "host.status", {:error, :closed}},
              {away, "host.status",
               {:error, %{"reason" => "host_unavailable", "message" => "the app is quitting"}}}
            ],
            do: mac_refusal(context, type, answer)

      empty = start_supervised!({HostAvailability, name: nil}, id: make_ref())

      unserved =
        refusal(
          [
            placement: :here,
            provider: :mac_app,
            host_availability: empty,
            request: fn _l, _t, _p, _ms -> flunk("asked") end
          ],
          away
        )

      answered ++ [unserved]
    end

    defp mac_refusal(context, type, answer) do
      record = start_supervised!({HostAvailability, name: nil}, id: make_ref())
      link = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(link, :kill) end)
      :ok = HostAvailability.listening(record, link)
      :ok = HostAvailability.attached(record, link, 1, "0.6.0")
      request = fn ^link, ^type, _payload, _timeout_ms -> answer end

      refusal(
        [placement: :here, provider: :mac_app, host_availability: record, request: request],
        context
      )
    end

    defp refusal(opts, context \\ %{}) do
      assert {:error, sentence} = Notifications.ready(context, opts)
      sentence
    end
  end

  describe "ready/2" do
    test "on Linux it is the session bus's answer" do
      assert Notifications.ready(%{}, dbus(%{"NameHasOwner" => {:ok, "b true\n"}})) == :ok

      assert Notifications.ready(%{}, dbus(%{"NameHasOwner" => {:ok, "b false\n"}})) ==
               {:error, @no_server}
    end

    test "a build that offers none is not ready, and asks nothing" do
      assert Notifications.ready(%{}, [host: @brew_mac] ++ nothing_runs()) ==
               {:error, @brew_sentence}
    end
  end

  describe "post/2" do
    test "posts through the resolved backend and answers its id" do
      assert Notifications.post(@notification, server({:ok, "u 42\n"})) == {:ok, "42"}
    end

    test "a build that offers none is not_offered, and nothing substitutes" do
      assert Notifications.post(@notification, [host: @brew_mac] ++ nothing_runs()) ==
               {:error, :not_offered}
    end

    test "a malformed notification is refused before any backend" do
      # Dynamic dispatch so the type checker doesn't flag the deliberately
      # malformed map at compile time.
      assert_raise FunctionClauseError, fn ->
        apply(Notifications, :post, [
          %{title: "Tea", body: @text},
          [host: @brew_mac] ++ nothing_runs()
        ])
      end
    end
  end

  describe "send_message/3, the computer delivery adapter" do
    test "a due reminder rings: the title as summary, the rendered text as body, with sound" do
      send_opts = [title: "Tea", proactive_key: "temporal:r1"] ++ server({:ok, "u 42\n"})

      assert Notifications.send_message("local", @text, send_opts) == :ok

      assert_received {:busctl, _owner}
      assert_received {:busctl, notify}
      # After Notify, its signature, app_name, replaces_id and app_icon.
      summary_at = Enum.find_index(notify, &(&1 == "Notify")) + 5
      assert ["Tea", @text] == notify |> Enum.drop(summary_at) |> Enum.take(2)

      assert ["sound-name", "s", "alarm-clock-elapsed"] ==
               notify |> Enum.drop(-1) |> Enum.take(-3)
    end

    test "the reminder's id reaches the Mac app, which offers Snooze 10 minutes for it" do
      send_opts =
        [title: "Tea", reminder_id: "rem_1"] ++ mac_app({:ok, %{"notification_id" => "n"}})

      assert Notifications.send_message("local", @text, send_opts) == :ok

      assert_received {:posted,
                       %{"reminder_id" => "rem_1", "actions" => [%{"id" => "snooze_10m"}]}}
    end

    test "a delivery for no reminder names none, and D-Bus ignores the id either way" do
      assert Notifications.send_message(
               "local",
               @text,
               [title: "Tea"] ++ mac_app({:ok, %{"notification_id" => "n"}})
             ) ==
               :ok

      assert_received {:posted, payload}
      refute Map.has_key?(payload, "reminder_id")

      for opts <- [[title: "Tea"], [title: "Tea", reminder_id: "rem_1"]] do
        assert Notifications.send_message("local", @text, opts ++ server({:ok, "u 1\n"})) == :ok
        assert_received {:busctl, _owner}
        assert_received {:busctl, notify}
        refute "rem_1" in notify
      end
    end

    test "a reminder id that is not one is refused before any call" do
      for bad <- ["", 7] do
        opts = [title: "Tea", reminder_id: bad] ++ nothing_runs()

        assert Notifications.send_message("local", @text, opts) ==
                 {:error, {:permanent, :malformed_request}}
      end
    end

    test "each Mac answer lands in the closed vocabulary" do
      rows = [
        {{:error, %{"reason" => "not_authorized", "message" => "off"}},
         {:permanent, :authorization}},
        {{:error, %{"reason" => "post_failed", "message" => "refused"}},
         {:permanent, :remote_rejected}},
        {{:error, :closed}, {:transport, :timeout}},
        {{:error, :timeout}, {:transport, :timeout}}
      ]

      for {answer, error} <- rows do
        opts = [title: "Tea", reminder_id: "rem_1"] ++ mac_app(answer)

        assert Notifications.send_message("local", @text, opts) == {:error, error},
               inspect(answer)
      end
    end

    test "each Linux failure lands in the closed vocabulary" do
      no_bus =
        {:error, {:helper_failed, 1, "Failed to connect to bus: No such file or directory"}}

      rows = [
        {dbus(%{"NameHasOwner" => no_bus}), {:transport, :connection_refused}},
        {dbus(%{"NameHasOwner" => {:ok, "b false\n"}}), {:transport, :connection_refused}},
        {[placement: :here, provider: :dbus, find_executable: fn "busctl" -> nil end],
         {:permanent, :adapter_unavailable}},
        {dbus(%{"NameHasOwner" => {:error, :timeout}}), {:transport, :timeout}},
        {server({:error, {:helper_failed, 1, "Call failed: Invalid argument"}}),
         {:permanent, :remote_rejected}},
        {[host: @brew_mac] ++ nothing_runs(), {:permanent, :adapter_unavailable}}
      ]

      for {opts, error} <- rows do
        assert Notifications.send_message("local", @text, [title: "Tea"] ++ opts) ==
                 {:error, error}
      end
    end

    test "a destination other than this computer's is refused before any call" do
      assert Notifications.send_message("chat-1", @text, [title: "Tea"] ++ nothing_runs()) ==
               {:error, {:permanent, :invalid_destination}}
    end

    test "a delivery without the event's title is refused before any call" do
      for opts <- [[], [title: ""], [title: nil]] do
        assert Notifications.send_message("local", @text, opts ++ nothing_runs()) ==
                 {:error, {:permanent, :malformed_request}}
      end
    end
  end

  describe "placement/1 (M99 §10.1)" do
    # The three facts, each a seam that says when it was read.
    defp facts(role, always_on, check) do
      test = self()

      [
        role: role,
        always_on: always_on,
        home: "/nonexistent/fermix-home",
        server_primary: fn "/nonexistent/fermix-home" ->
          send(test, :device_list_read)
          check
        end
      ]
    end

    test "an Always On server's primary rings on the owner's computers" do
      assert Notifications.placement(facts(:primary, true, :server)) == {:ok, :computers}
    end

    test "a primary that is no server's rings here" do
      for check <- [{:not_server, :macos}, {:not_server, :no_desktop}] do
        assert Notifications.placement(facts(:primary, true, check)) == {:ok, :here}
      end
    end

    test "without Always On a primary rings here, and its device list is not read" do
      assert Notifications.placement(facts(:primary, false, :server)) == {:ok, :here}
      refute_received :device_list_read
    end

    # A desktop whose home moved keeps its own desktop row in the retired copy,
    # which would read as a server's: its role decides first.
    test "a device, a candidate and an engine with no boot ring here, reading nothing" do
      for role <- [:device, :candidate, nil] do
        assert Notifications.placement(facts(role, true, :server)) == {:ok, :here}, inspect(role)
      end

      refute_received :device_list_read
    end

    test "a device list that cannot be read is an error in a clause, never here" do
      assert {:error, clause} =
               Notifications.placement(
                 facts(:primary, true, {:not_server, {:device_list, :eacces}})
               )

      assert clause =~ "device list could not be read"
      refute String.ends_with?(clause, ".")
      assert String.first(clause) == "t"
    end

    test "a named placement decides, and one outside the two raises" do
      assert Notifications.placement(placement: :computers) == {:ok, :computers}
      assert Notifications.placement(placement: :here) == {:ok, :here}
      assert_raise ArgumentError, fn -> Notifications.placement(placement: :phone) end
    end
  end

  describe "resolve/1 by placement (M99 §10.1)" do
    test "on the owner's computers, a Linux build resolves the computers' backend" do
      assert Notifications.resolve(provider: :dbus, placement: :computers) ==
               {:ok,
                %{
                  provider: :dbus,
                  placement: :computers,
                  module: Notifications.Computers,
                  source: :given
                }}
    end

    test "a Mac app's engine placed on computers cannot happen, and raises" do
      assert_raise ArgumentError, fn ->
        Notifications.resolve(host: @mac_app, placement: :computers)
      end
    end

    test "a placement that cannot be read refuses, and a post fails in its words" do
      unread = [
        provider: :dbus,
        role: :primary,
        always_on: true,
        server_primary: fn _home -> {:not_server, {:device_list, :eacces}} end,
        home: "/nonexistent/fermix-home"
      ]

      assert {:error, clause} = Notifications.resolve(unread)
      assert Notifications.post(@notification, unread) == {:error, {:failed, clause}}

      assert Notifications.send_message("local", @text, [title: "Tea"] ++ unread) ==
               {:error, {:permanent, :remote_rejected}}
    end

    test "a build that offers none refuses before its placement is read" do
      assert Notifications.resolve(
               host: @brew_mac,
               server_primary: fn _home -> flunk("the device list was read") end,
               role: :primary,
               always_on: true
             ) == {:error, @brew_sentence}
    end

    test "offered?/1 is the build's fact alone: no placement is read" do
      never = [
        role: :primary,
        always_on: true,
        server_primary: fn _home -> flunk("the device list was read") end
      ]

      assert Notifications.offered?([host: %{profile: :linux_package_cli, os: :linux}] ++ never)
      assert Notifications.offered?([host: @mac_app] ++ never)
      refute Notifications.offered?([host: @brew_mac] ++ never)
    end
  end

  describe "a home on this computer never touches the link (M99 §10.1)" do
    # The facts a Mac primary reads, and a computers' backend that fails the
    # test if it is ever reached.
    defp mac_primary do
      [
        role: :primary,
        always_on: true,
        home: "/nonexistent/fermix-home",
        server_primary: fn _home -> {:not_server, :macos} end,
        computers: [rows: fn -> flunk("the home's computers were listed") end],
        call: fn _c, _m, _o, _a, _ctx, _opts -> flunk("a computer was called") end
      ]
    end

    test "a Mac's reminder posts through the app, as it did, its key unsent" do
      opts = Keyword.delete(mac_app({:ok, %{"notification_id" => "n"}}), :placement)
      send_opts = [title: "Tea", reminder_id: "rem_1", proactive_key: "temporal:rem_1"]

      assert Notifications.send_message("local", @text, send_opts ++ opts ++ mac_primary()) ==
               :ok

      assert_received {:posted, payload}
      assert payload["reminder_id"] == "rem_1"
      refute Map.has_key?(payload, "key")
      refute inspect(payload) =~ "temporal:rem_1"
    end

    test "a Linux desktop's reminder posts on its own bus, its key unsent" do
      opts = Keyword.delete(server({:ok, "u 9\n"}), :placement)

      linux_primary =
        Keyword.put(mac_primary(), :server_primary, fn _home -> {:not_server, :no_desktop} end)

      send_opts = [title: "Tea", proactive_key: "temporal:rem_1"]

      assert Notifications.send_message("local", @text, send_opts ++ opts ++ linux_primary) ==
               :ok

      assert_received {:busctl, _owner}
      assert_received {:busctl, notify}
      refute "temporal:rem_1" in notify
    end

    test "on a server the reminder's key travels to the computers" do
      test = self()

      call = fn computer, _module, "post", args, _context, _opts ->
        send(test, {:asked, computer.name, args})
        {:ok, %FermixCore.Computers.Outcome{status: :ok, result: %{"shown" => "now"}}}
      end

      row = %{
        device_id: "dev-1",
        name: "studio Mac",
        platform: "macos",
        last_seen: nil,
        backups: nil,
        connected: true,
        since: ~U[2031-06-08 11:00:00Z]
      }

      server = [
        placement: :computers,
        provider: :dbus,
        call: call,
        computers: [
          role: :primary,
          rows: fn -> {:ok, [row]} end,
          live: %{
            "dev-1" => %{offers: [%{id: "files", state: :on}], path: :direct, standing: :current}
          },
          records: %{},
          version: "0.18.0"
        ]
      ]

      send_opts = [title: "Tea", reminder_id: "rem_1", proactive_key: "temporal:rem_1"]
      assert Notifications.send_message("local", @text, send_opts ++ server) == :ok

      assert_received {:asked, "studio Mac",
                       %{"key" => "temporal:rem_1", "reminder_id" => "rem_1"}}
    end

    test "a proactive key that is not one is refused before any call" do
      for bad <- ["", 7] do
        opts = [title: "Tea", proactive_key: bad] ++ nothing_runs()

        assert Notifications.send_message("local", @text, opts) ==
                 {:error, {:permanent, :malformed_request}}
      end
    end
  end

  describe "delivery_error/1" do
    # M76 §4.6's table, a row per reason a backend answers, and whether the
    # rail's ladder retries it on the same target.
    @rows [
      {:host_unavailable, {:transport, :timeout}, true},
      {:not_authorized, {:permanent, :authorization}, false},
      {:no_server, {:transport, :connection_refused}, true},
      {:no_computer, {:transport, :connection_refused}, true},
      {:backend_missing, {:permanent, :adapter_unavailable}, false},
      {:not_offered, {:permanent, :adapter_unavailable}, false},
      {:timeout, {:transport, :timeout}, true},
      {{:failed, "Notify: exit 1: Call failed"}, {:permanent, :remote_rejected}, false}
    ]

    test "every reason maps to one error of the closed vocabulary, retried as the table says" do
      for {reason, error, retried?} <- @rows do
        assert Notifications.delivery_error(reason) == error, inspect(reason)
        assert Error.normalize({:error, error}) == {:error, error}, inspect(error)
        assert Error.retryable?(error) == retried?, inspect(error)
      end
    end

    test "a reason outside the vocabulary is refused" do
      # Dynamic dispatch so the type checker doesn't flag the deliberately
      # off-contract reason at compile time; the fail-loud behavior is what we assert.
      assert_raise FunctionClauseError, fn ->
        apply(Notifications, :delivery_error, [:busy])
      end
    end
  end

  describe "through ChannelSend, as the reminder rail sends" do
    @channels %{"computer" => Notifications}

    test "the computer platform resolves to the adapter" do
      assert Notifications.platform() == "computer"
      assert Notifications.destination() == "local"

      assert ChannelSend.resolve_adapter(Notifications.platform(), channels: @channels) ==
               {:ok, Notifications}
    end

    test "one bounded send reaches the server, and a refusal normalizes as the rail reads it" do
      delivered =
        rail_send([title: "Tea", proactive_key: "temporal:r1"] ++ server({:ok, "u 3\n"}))

      assert delivered == :ok

      refused = rail_send([title: "Tea"] ++ dbus(%{"NameHasOwner" => {:ok, "b false\n"}}))
      assert refused == {:error, {:transport, :connection_refused}}
    end

    # `Temporal.Delivery.attempt/4`'s shape: one send under the watchdog, its
    # whole result normalized.
    defp rail_send(send_opts) do
      30_000
      |> ChannelSend.with_timeout(fn ->
        ChannelSend.send(
          Notifications.platform(),
          Notifications.destination(),
          @text,
          send_opts,
          channels: @channels,
          delivery_max_attempts: 1
        )
      end)
      |> Error.normalize()
    end
  end

  @config_exs Path.expand("../../../../../config/config.exs", __DIR__)

  # The reminder rail resolves a stored `computer` row's adapter from the
  # shipped channels map at every attempt, so the map names this module beside
  # the chat platforms. A build that offers no notifications still resolves it
  # and answers its own refusal, never a missing adapter.
  test "the shipped delivery channels map the computer platform to this adapter" do
    channels =
      @config_exs
      |> Config.Reader.read!(env: :prod, target: :host)
      |> Keyword.fetch!(:fermix_core)
      |> Keyword.fetch!(:jobs)
      |> Keyword.fetch!(:delivery_channels)

    assert Map.fetch!(channels, Notifications.platform()) == Notifications
  end
end
