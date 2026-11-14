defmodule FermixCore.Home.JoinTest do
  # M97 §3.1, §17: a computer joining a home that already runs. Its key goes
  # to the stub keychain (one table for the VM), so every home names a
  # profile of its own.
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias FermixCore.ComputerHistory.Spool
  alias FermixCore.Computers.Switches
  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.EnrollmentCode
  alias FermixCore.Home.Join
  alias FermixCore.Home.Leave
  alias FermixCore.Home.Moved
  alias FermixCore.Home.Role
  alias FermixCore.Memory.Repo
  alias FermixCore.Setup.ConfigStore
  alias FermixTestSupport.SafeRm

  @now ~U[2031-05-04 10:00:00Z]
  @gateway :binary.copy(<<0x3C>>, 32)
  @style "Answer in a few sentences, and go longer when the question needs it."

  setup do
    tmp = SafeRm.make_tmp_dir!("home_join")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    test = self()

    opts = [
      now: @now,
      # No relay runs here: the link says nothing of its server.
      link_status: fn -> %{primary: nil} end,
      restart: fn ->
        send(test, :restarted)
        :ok
      end
    ]

    %{home: home!(tmp, "loft"), tmp: tmp, opts: opts}
  end

  describe "start" do
    test "makes the key, the join and the device role, then restarts", ctx do
      assert :ok = Join.start(ctx.home, code(), ctx.opts)
      assert_received :restarted

      assert {:ok, state} = Join.read(ctx.home)
      assert state["phase"] == "dialing"
      assert state["server"]["name"] == "studio-mac"
      assert state["key"] == "@keyring"
      assert Bitwise.band(File.stat!(Join.path(ctx.home)).mode, 0o777) == 0o600

      {:ok, %{public: public}} = ComputerKey.read(ctx.home, store: :keyring)
      assert state["public"] == Base.encode64(public)
      assert {:ok, %{role: :device}} = Role.configured(ctx.home)
      assert Join.view(ctx.home)["sentence"] == "Connecting to your Fermix on studio-mac."
    end

    # "A home of its own": anything a person made here refuses it by name.
    test "a computer with a home of its own is refused by name, and nothing is written", ctx do
      cases = [
        {"messages", &memory!(&1, :message)},
        {"memories", &memory!(&1, :fact)},
        {"memories", &memory!(&1, :renamed)},
        {"memories", &memory!(&1, :forgotten)},
        {"scheduled jobs", &memory!(&1, :job)},
        {"computer history", &memory!(&1, :note)},
        {"a paired phone or computer", &paired!/1},
        {"a home that moved to a server", &moved!/1},
        {"a link to a server", &linked!/1}
      ]

      for {{what, make}, n} <- Enum.with_index(cases) do
        home = home!(ctx.tmp, "own-#{n}")
        make.(home)

        assert Join.start(home, code(), ctx.opts) == {:error, {:home_of_its_own, what}}

        assert Join.error_sentence({:home_of_its_own, what}) =~
                 "a Fermix of its own (it holds #{what})"

        refute Join.present?(home)
        assert ComputerKey.read(home, store: :keyring) == {:error, {:missing, :keyring}}
      end

      refute_received :restarted
    end

    # A first start leaves files nothing uses: they are no home, and stay.
    test "the files a first start leaves are no home of its own, and are left alone", ctx do
      memory!(ctx.home, nil)
      File.write!(Path.join(ctx.home, "mobile_epoch_note"), "unused\n")

      assert :ok = Join.start(ctx.home, code(), ctx.opts)
      assert File.regular?(Path.join(ctx.home, "memory.db"))
      assert File.regular?(Path.join(ctx.home, "mobile_epoch_note"))
    end

    # M97 §3.1: a first start, and every save of the settings, writes the
    # owner's name, time zone and style and the agent's name into memory as
    # well. Memories that only repeat the settings are no home of their own:
    # a first start on a headless box (its name from the account), a Mac
    # whose owner answered About you, and a machine that gave no name.
    test "memories that only repeat the settings are no home of its own, and stay", ctx do
      first_start =
        {%{user_name: "Rowan Vale", timezone: "Etc/UTC", communication_style: @style}, nil}

      about_you =
        {%{user_name: "Avery Quinn", timezone: "America/Chicago", communication_style: "Brief."},
         "Juno"}

      no_name = {%{timezone: "Europe/Lisbon", communication_style: @style}, nil}

      for {{personalization, agent_name}, n} <-
            Enum.with_index([first_start, about_you, no_name]) do
        home = home!(ctx.tmp, "settings-#{n}")
        settings!(home, personalization, agent_name)
        memory!(home, nil, setting_rows(personalization, agent_name))

        assert :ok = Join.start(home, code(), ctx.opts), inspect(personalization)
        assert memory_count(home) == 4
      end
    end

    test "a code that is not a computer's, or expired, is refused before anything is made", ctx do
      assert Join.start(ctx.home, code(purpose: :candidate), ctx.opts) ==
               {:error, {:code_purpose, :candidate}}

      assert Join.start(ctx.home, code(expires_at: ~U[2031-05-04 09:59:59Z]), ctx.opts) ==
               {:error, :code_expired}

      assert {:error, {:invalid_code, _what}} = Join.start(ctx.home, "fxenroll1.nope", ctx.opts)

      refute Join.present?(ctx.home)
      assert ComputerKey.read(ctx.home, store: :keyring) == {:error, {:missing, :keyring}}
      assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
    end

    test "a store that holds another home's key is refused by name, leaving it", ctx do
      other = home!(ctx.tmp, "other", profile_of(ctx.home))
      {:ok, kept, :keyring} = ComputerKey.create(other)

      assert Join.start(ctx.home, code(), ctx.opts) ==
               {:error, {:computer_key, {:in_use, :keyring}}}

      assert ComputerKey.read(other, store: :keyring) == {:ok, kept}
      refute Join.present?(ctx.home)
    end

    test "a second join while one runs is refused", ctx do
      :ok = Join.start(ctx.home, code(), ctx.opts)
      assert Join.start(ctx.home, code(), ctx.opts) == {:error, :computer_join_running}
    end

    # A step that fails takes back the key it made, so the next join is not
    # refused by a key nothing records.
    test "a join that cannot be written takes back its key, and the next join starts", ctx do
      blocked = Join.path(ctx.home) <> ".tmp"
      File.mkdir_p!(Path.join(blocked, "kept"))

      assert {:error, {:file, _path, _reason}} = Join.start(ctx.home, code(), ctx.opts)
      assert ComputerKey.read(ctx.home, store: :keyring) == {:error, {:missing, :keyring}}
      refute Join.present?(ctx.home)
      refute_received :restarted

      SafeRm.rm_rf!(blocked)
      assert :ok = Join.start(ctx.home, code(), ctx.opts)
      assert_received :restarted
    end
  end

  test "a denial is recorded with its sentence, and the code's secret leaves the file", ctx do
    :ok = Join.start(ctx.home, code(), ctx.opts)
    :ok = Join.record(ctx.home, "awaiting_approval", %{"sas" => "482913"})
    assert Join.view(ctx.home)["sas"] == "482913"

    :ok = Join.record(ctx.home, "denied", %{"sentence" => "studio-mac did not add it."})

    assert {:ok, %{"phase" => "denied", "secret" => nil}} = Join.read(ctx.home)
    assert Join.view(ctx.home)["sentence"] == "studio-mac did not add it."
  end

  test "cancel takes back the key and the join, and the home is its own again", ctx do
    :ok = Join.start(ctx.home, code(), ctx.opts)
    assert_received :restarted

    assert :ok = Join.cancel(ctx.home, ctx.opts)
    assert_received :restarted
    refute Join.present?(ctx.home)
    assert ComputerKey.read(ctx.home, store: :keyring) == {:error, {:missing, :keyring}}
    assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
    assert Join.cancel(ctx.home, ctx.opts) == {:error, :not_joining}
  end

  test "the server's approval links this computer, every offer off", ctx do
    :ok = Join.start(ctx.home, code(), ctx.opts)
    {:ok, keypair} = ComputerKey.read(ctx.home, store: :keyring)
    # Its recorder was on before it joined; its history would now go to the
    # server, so it starts off with the rest (M97 §3.1, §7.3, D27).
    :ok =
      ConfigStore.put_machine_table(ctx.home, "fermix_core.computer_history", [
        {"enabled", "true"}
      ])

    approved = %{
      "device_id" => "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b",
      "name" => "loft-linux",
      "primary_epoch" => 6,
      "primary" => %{
        "name" => "studio-mac",
        "node_id" => String.duplicate("4f", 32),
        "relays" => [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        "relays_rev" => "0123456789abcdef",
        "addrs" => ["100.101.102.103:4033"]
      }
    }

    assert :ok = Join.finish(ctx.home, approved, ctx.opts)
    refute Join.present?(ctx.home)

    assert {:ok, link} = DesktopLink.read(ctx.home)
    assert {link.device_id, link.key, link.epoch} == {approved["device_id"], :keyring, 6}
    assert link.primary.gateway_pk == @gateway
    assert link.primary.addrs == ["100.101.102.103:4033"]
    assert ComputerKey.read(ctx.home) == {:ok, keypair}

    # A computer that joins starts with every offer off, reviewed (M97 §7.3),
    # but Apple Maps, whose switch is on by default (M89 D13).
    assert {:ok, switches} = Switches.read(ctx.home)
    assert Switches.switched_on(switches) == [:places]
    assert Switches.reviewed?(switches) and Switches.enabled?(switches)

    assert {:ok, %{"enabled" => false}} =
             ConfigStore.machine_table(ctx.home, "fermix_core.computer_history")
  end

  # M97 §8.5: a machine's purge mark counts one home's intervals, so joining
  # a home forgets the mark an earlier home left.
  test "the server's approval forgets the history mark of an earlier home", ctx do
    spool = marked_spool!(ctx.home)
    :ok = Join.start(ctx.home, code(), ctx.opts)

    assert :ok = Join.finish(ctx.home, approved(), ctx.opts)
    assert {:ok, %{home_mark: 0, home: nil}} = Spool.link(server: spool)
  end

  # M97 §3.3: a computer leaves; the home is told first.
  describe "disconnect" do
    setup ctx do
      :ok = Join.start(ctx.home, code(), ctx.opts)
      :ok = Join.finish(ctx.home, approved(), ctx.opts)
      flush_restarts()
      :ok
    end

    test "tells the server, then lets go of the key, the link and the switches", ctx do
      test = self()

      forward = fn request, _opts ->
        send(test, {:forwarded, request.method, request.params})
        {:ok, %{"device_id" => request.params["device_id"], "revoked" => true}}
      end

      assert {:ok, true} = Leave.disconnect(ctx.home, [forward: forward] ++ ctx.opts)

      assert_received {:forwarded, "mobile.devices.revoke",
                       %{
                         "device_id" => "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b",
                         "confirmed" => true
                       }}

      assert_received :restarted
      refute File.exists?(DesktopLink.path(ctx.home))
      assert ComputerKey.read(ctx.home, store: :keyring) == {:error, {:missing, :keyring}}
      assert Switches.read(ctx.home) == {:ok, []}
      assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
    end

    test "a server that cannot be told changes nothing, unless the owner confirmed", ctx do
      unreachable = fn _request, _opts ->
        {:error, :primary_unreachable, %{"sentence" => "The server studio-mac is unreachable."}}
      end

      assert Leave.disconnect(ctx.home, [forward: unreachable] ++ ctx.opts) ==
               {:error, :not_told}

      assert File.exists?(DesktopLink.path(ctx.home))
      refute_received :restarted

      assert {:ok, false} =
               Leave.disconnect(ctx.home, [forward: unreachable, confirmed: true] ++ ctx.opts)

      refute File.exists?(DesktopLink.path(ctx.home))
    end

    # The server removes the computer and ends its session at once, so the
    # answer to its own request never arrives: the link then says the server
    # no longer knows this computer, which is the server having taken it.
    test "a server that ended the session as it removed this computer was told", ctx do
      lost = fn _request, _opts ->
        {:error, :primary_unreachable, %{"sentence" => "The server studio-mac is unreachable."}}
      end

      revoked = fn -> %{primary: %{status: :revoked, connected: false}} end
      opts = [forward: lost, link_status: revoked] ++ ctx.opts

      assert {:ok, true} = Leave.disconnect(ctx.home, opts)
      assert_received :restarted
      refute File.exists?(DesktopLink.path(ctx.home))
    end

    # The link goes last, so a step that fails before it leaves this computer
    # linked, and asking again finishes the job.
    test "a disconnect that fails part-way finishes when asked again", ctx do
      told = fn request, _opts -> {:ok, %{"device_id" => request.params["device_id"]}} end
      opts = [forward: told] ++ ctx.opts
      machine = Path.join(ctx.home, "machine.toml")
      SafeRm.rm!(machine)
      File.mkdir_p!(Path.join(machine, "kept"))

      assert {:error, {:config, _reason}} = Leave.disconnect(ctx.home, opts)
      refute_received :restarted

      SafeRm.rm_rf!(machine)
      assert {:ok, true} = Leave.disconnect(ctx.home, opts)
      assert_received :restarted
      refute File.exists?(DesktopLink.path(ctx.home))
      assert ComputerKey.read(ctx.home, store: :keyring) == {:error, {:missing, :keyring}}
      assert {:ok, %{role: :primary}} = Role.configured(ctx.home)
    end

    test "a moved marker that cannot be read refuses before anything changes", ctx do
      test = self()
      File.write!(Moved.path(ctx.home), "not a marker")

      forward = fn request, _opts ->
        send(test, {:forwarded, request.method})
        {:ok, %{}}
      end

      assert {:error, {:moved, _reason} = reason} =
               Leave.disconnect(ctx.home, [forward: forward] ++ ctx.opts)

      assert Leave.error_sentence(reason) in Leave.sentences()
      refute_received {:forwarded, _method}
      assert File.exists?(DesktopLink.path(ctx.home))
      assert {:ok, %{public: _public}} = ComputerKey.read(ctx.home, store: :keyring)
    end

    test "a disconnect forgets the history mark of the home it left", ctx do
      spool = marked_spool!(ctx.home)
      told = fn request, _opts -> {:ok, %{"device_id" => request.params["device_id"]}} end

      assert {:ok, true} = Leave.disconnect(ctx.home, [forward: told] ++ ctx.opts)
      assert {:ok, %{home_mark: 0, home: nil}} = Spool.link(server: spool)
    end

    test "the computer a home moved from stays retired, in the device role", ctx do
      :ok = Moved.write(ctx.home, %{to: "studio-mac", moved_at: @now, epoch: 5})
      :ok = ConfigStore.put_engine_role(ctx.home, :device)
      ok = fn _request, _opts -> {:ok, %{}} end

      assert {:ok, true} = Leave.disconnect(ctx.home, [forward: ok] ++ ctx.opts)
      assert {:ok, %{role: :device}} = Role.configured(ctx.home)
    end
  end

  # -- facts ----------------------------------------------------------------------

  # This machine's history store, holding the mark 7 of an earlier home.
  defp marked_spool!(home) do
    spool =
      start_supervised!({Spool, name: nil, path: Spool.path(home)}, id: :machine_spool)

    pause = %{id: 7, from_ts: 1, to_ts: 2, issued_at: 1, kind: "pause"}
    :ok = Spool.apply_intervals([pause], "earlier-home.3", @now, server: spool)
    {:ok, %{home_mark: 7, home: "earlier-home.3"}} = Spool.link(server: spool)
    spool
  end

  defp home!(tmp, name, profile \\ nil) do
    home = Path.join(tmp, name)
    File.mkdir_p!(home)
    profile = profile || "join-#{name}-#{System.unique_integer([:positive])}"
    File.write!(Path.join(home, "config.toml"), ~s([fermix_core]\nprofile = "#{profile}"\n))
    home
  end

  defp profile_of(home) do
    [_all, profile] =
      Regex.run(~r/profile = "([^"]+)"/, File.read!(Path.join(home, "config.toml")))

    profile
  end

  defp code(overrides \\ []) do
    facts =
      Map.merge(
        %{
          purpose: :computer,
          secret: :binary.copy(<<0x5A>>, 32),
          gateway_pk: @gateway,
          node_id: String.duplicate("4f", 32),
          relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
          relays_rev: "0123456789abcdef",
          name: "studio-mac",
          expires_at: ~U[2031-05-04 10:30:00Z]
        },
        Map.new(overrides)
      )

    {:ok, code} = EnrollmentCode.encode(facts)
    code
  end

  defp approved do
    %{
      "device_id" => "7e1f0c2a-3b4d-4e5f-8a6b-7c8d9e0f1a2b",
      "name" => "loft-linux",
      "primary_epoch" => 6,
      "primary" => %{
        "name" => "studio-mac",
        "node_id" => String.duplicate("4f", 32),
        "relays" => [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        "relays_rev" => "0123456789abcdef"
      }
    }
  end

  # A memory.db as the engine makes it (its own repo migrates it, then
  # stops), holding the memories a first start's seed writes from settings
  # that name nothing (`settings`, when given, in their place), plus one
  # thing a person made here (none when nil).
  defp memory!(home, made, settings \\ nil) do
    db = Path.join(home, "memory.db")
    name = :"join_repo_#{System.unique_integer([:positive])}"
    start_supervised!({Repo, name: name, enabled: true, database_path: db}, id: name)
    :ok = stop_supervised!(name)
    seeded = settings || setting_rows(%{}, nil)

    {:ok, conn} = Sqlite3.open(db)
    for row <- seeded, do: :ok = insert!(conn, "memories", row)
    if made, do: :ok = made!(conn, made)
    :ok = Sqlite3.close(conn)
  end

  # The four rows `Prompt.SetupSeeder` writes for these settings, as the
  # first start on the test box wrote them (M97 finding F1).
  defp setting_rows(personalization, agent_name) do
    [
      {"owner", "identity", "name", Map.get(personalization, :user_name, "there"), "user_md"},
      {"owner", "identity", "timezone", Map.get(personalization, :timezone, "not set"),
       "user_md"},
      {"owner", "preference", "communication style",
       Map.get(personalization, :communication_style, "neutral and direct"), "user_md"},
      {"agent", "identity", "agent name", agent_name || "fermix", "memory_md"}
    ]
    |> Enum.map(fn {scope, category, key, value, target} ->
      %{
        "scope_type" => scope,
        "scope_id" => if(scope == "owner", do: "default", else: "main"),
        "category" => category,
        "key" => key,
        "value" => value,
        "promote_target" => target
      }
    end)
  end

  defp made!(conn, :message),
    do:
      insert!(conn, "messages", %{
        "channel" => "telegram",
        "chat_id" => "4107",
        "sender" => "owner",
        "role" => "user",
        "content" => "Is the allotment gate open on Sundays?"
      })

  # A fact a conversation saved beside the settings' rows.
  defp made!(conn, :fact),
    do:
      insert!(conn, "memories", %{
        "scope_type" => "owner",
        "scope_id" => "default",
        "category" => "fact",
        "key" => "allotment gate code",
        "value" => "4417",
        "promote_target" => "user_md"
      })

  # A conversation saved the owner's name over the one the settings hold.
  defp made!(conn, :renamed),
    do:
      Sqlite3.execute(
        conn,
        "UPDATE memories SET value = 'Ro' WHERE scope_type = 'owner' AND key = 'name'"
      )

  # A conversation archived one of them.
  defp made!(conn, :forgotten),
    do:
      Sqlite3.execute(
        conn,
        "UPDATE memories SET archived_at = '2031-05-03T09:00:00Z' WHERE key = 'timezone'"
      )

  defp made!(conn, :job),
    do:
      insert!(conn, "scheduled_jobs", %{
        "id" => "job-seed-order",
        "name" => "Seed order",
        "schedule_kind" => "cron",
        "schedule_expr" => "0 9 * * 1",
        "timezone" => "America/Chicago",
        "task_prompt" => "Remind me to order the tomato seeds.",
        "memory_source_id" => "source-seed-order",
        "created_by_trust" => "operator"
      })

  defp made!(conn, :note),
    do:
      insert!(conn, "computer_history_memories", %{
        "created_at" => 1_946_000_000,
        "provenance_from_ts" => 1_945_990_000,
        "provenance_to_ts" => 1_945_994_000,
        "summary" => "Drafted the reply to the Juniper Street lease renewal.",
        "model" => "local"
      })

  defp insert!(conn, table, row) do
    {columns, values} = Enum.unzip(row)
    marks = Enum.map_join(values, ", ", fn _value -> "?" end)
    sql = "INSERT INTO #{table} (#{Enum.join(columns, ", ")}) VALUES (#{marks})"
    {:ok, statement} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(statement, values)
    :done = Sqlite3.step(conn, statement)
    :ok = Sqlite3.release(conn, statement)
  end

  defp memory_count(home) do
    {:ok, conn} = Sqlite3.open(Path.join(home, "memory.db"), mode: :readonly)
    {:ok, statement} = Sqlite3.prepare(conn, "SELECT count(*) FROM memories")
    {:row, [count]} = Sqlite3.step(conn, statement)
    :ok = Sqlite3.release(conn, statement)
    :ok = Sqlite3.close(conn)
    count
  end

  # The settings the seed's rows repeat, as the settings file holds them.
  defp settings!(home, personalization, agent_name) do
    lines =
      for {key, value} <- personalization, do: ~s(#{key} = "#{value}"\n)

    agent = if agent_name, do: ~s(\n[fermix_core.agent]\nname = "#{agent_name}"\n), else: ""

    File.write!(
      Path.join(home, "config.toml"),
      "\n[fermix_core.personalization]\n#{lines}#{agent}",
      [:append]
    )
  end

  defp paired!(home) do
    File.mkdir_p!(Path.join(home, "mobile"))

    File.write!(Path.join([home, "mobile", "devices.toml"]), """
    [[devices]]
    device_id = "11111111-1111-4111-8111-111111111111"
    name = "Pixel"
    """)
  end

  defp moved!(home), do: :ok = Moved.write(home, %{to: "studio-mac", moved_at: @now, epoch: 5})

  defp linked!(home) do
    File.mkdir_p!(Path.join(home, "device"))
    File.write!(DesktopLink.path(home), "{}")
  end

  defp flush_restarts do
    receive do
      :restarted -> flush_restarts()
    after
      0 -> :ok
    end
  end
end
