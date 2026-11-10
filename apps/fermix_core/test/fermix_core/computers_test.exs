defmodule FermixCore.ComputersTest do
  # M97 §3.2, §6.5: the home's computers on the primary, from their rows, the
  # live facts of their sessions and their records.
  use ExUnit.Case, async: true

  alias FermixCore.Computers
  alias FermixCore.Computers.Computer

  @studio "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"
  @loft "0d3f8a7e-5c21-4b9e-8f60-2a4c6e8b1d37"
  @since ~U[2031-06-01 09:00:00Z]
  @seen ~U[2031-05-31 02:14:00Z]
  @files %{id: "files", state: :on, sentence: nil, detail: nil}
  @shell %{id: "shell", state: :on, sentence: nil, detail: "strict"}
  @history_off %{id: "history", state: :off, sentence: "Switched off on this Mac.", detail: nil}

  defmodule FakeLink do
    @moduledoc false
    def computer_rows, do: {:ok, Process.get(:fake_rows, [])}

    def rename_computer(device_id, name) do
      rows = Process.get(:fake_rows, [])

      cond do
        not Enum.any?(rows, &(&1.device_id == device_id)) ->
          {:error, {:not_found, device_id}}

        Enum.any?(
          rows,
          &(&1.device_id != device_id and String.downcase(&1.name) == String.downcase(name))
        ) ->
          {:error, {:name_taken, name}}

        true ->
          rows = Enum.map(rows, &if(&1.device_id == device_id, do: %{&1 | name: name}, else: &1))
          Process.put(:fake_rows, rows)
          {:ok, Enum.find(rows, &(&1.device_id == device_id))}
      end
    end
  end

  defp row(id, name, platform, overrides \\ []) do
    Map.merge(
      %{
        device_id: id,
        name: name,
        platform: platform,
        last_seen: nil,
        backups: nil,
        connected: false,
        since: nil
      },
      Map.new(overrides)
    )
  end

  defp opts(rows, overrides \\ []) do
    Process.put(:fake_rows, rows)

    Keyword.merge(
      [
        role: :primary,
        link: FakeLink,
        live: %{},
        records: %{},
        server_name: "garden server",
        version: "0.19.2"
      ],
      overrides
    )
  end

  describe "list" do
    # M97 §3.4: each computer stands against this server's version by the one
    # it last said; one past the window offers nothing until it updates.
    test "each computer stands against the server, and one past the window offers nothing" do
      rows = [
        row(@studio, "studio Mac", "macos", connected: true, since: @since),
        row(@loft, "loft Linux", "linux")
      ]

      records = %{
        @studio => %{engine_version: "0.16.4", seen_at: @seen, offers: [@files]},
        @loft => %{engine_version: "0.17.0", seen_at: @seen, offers: [@shell]}
      }

      live = %{@studio => %{offers: [@files, @shell], path: :relay, since: @since}}

      assert [loft, studio] = Computers.list(opts(rows, records: records, live: live))
      assert {loft.standing, loft.offers} == {:behind, [@shell]}
      assert {studio.standing, studio.offers} == {:settings_only, []}
      assert Computer.view(studio)["standing"] == "settings_only"

      ahead = %{@loft => %{engine_version: "0.20.0", seen_at: @seen}}
      assert [_loft, _studio] = listed = Computers.list(opts(rows, records: ahead, live: live))
      assert Enum.map(listed, & &1.standing) == [:ahead, nil]
      assert Computer.view(List.last(listed))["standing"] == nil
    end

    test "an away computer has its last offers and when the home last heard it" do
      rows = [row(@loft, "loft Linux", "linux", last_seen: ~U[2031-05-30 08:00:00Z])]
      records = %{@loft => %{engine_version: "0.19.0", seen_at: @seen, offers: [@files, @shell]}}

      assert [%Computer{} = loft] = Computers.list(opts(rows, records: records))

      assert loft.platform == :linux
      assert loft.engine_version == "0.19.0"
      refute loft.connected
      assert loft.last_seen == @seen
      assert loft.offers == [@files, @shell]
      assert loft.path == nil
      assert loft.backups
    end

    test "a connected computer offers what its session sent, nothing before" do
      rows = [row(@studio, "studio Mac", "macos", connected: true, since: @since, backups: false)]
      records = %{@studio => %{offers: [@files], seen_at: @seen}}

      waiting = %{@studio => %{offers: [], path: nil, since: @since}}
      assert [studio] = Computers.list(opts(rows, records: records, live: waiting))
      assert studio.connected
      assert studio.offers == []
      refute studio.backups

      sent = %{@studio => %{offers: [@files, @history_off], path: :direct, since: @since}}
      assert [studio] = Computers.list(opts(rows, records: records, live: sent))
      assert studio.offers == [@files, @history_off]
      assert studio.path == :direct
    end

    test "a computer that never sent offers offers nothing" do
      assert [%Computer{offers: []}] = Computers.list(opts([row(@loft, "loft Linux", nil)]))
    end

    test "there are none off the primary" do
      assert Computers.list(opts([row(@loft, "loft Linux", "linux")], role: :device)) == []
    end

    test "one is found by its id or its name, whatever the case" do
      rows = [row(@studio, "studio Mac", "macos"), row(@loft, "loft Linux", "linux")]

      assert {:ok, %{device_id: @loft}} = Computers.get("LOFT linux", opts(rows))
      assert {:ok, %{name: "studio Mac"}} = Computers.get(@studio, opts(rows))
      assert {:error, :not_found} = Computers.get("attic Mac", opts(rows))
    end
  end

  describe "rename" do
    test "a name is unique in the home without case, and not the server's" do
      rows = [row(@studio, "studio Mac", "macos"), row(@loft, "loft Linux", "linux")]

      assert {:ok, %{name: "attic Linux"}} = Computers.rename(@loft, "  attic Linux ", opts(rows))

      assert {:error, {:name_taken, "Another computer of yours is already called STUDIO mac."}} =
               Computers.rename(@loft, "STUDIO mac", opts(Process.get(:fake_rows)))

      assert {:error, {:name_taken, "Your server is already called Garden Server."}} =
               Computers.rename(@loft, "Garden Server", opts(Process.get(:fake_rows)))

      assert {:error, {:invalid_name, _sentence}} =
               Computers.rename(@loft, "two\nlines", opts(Process.get(:fake_rows)))

      assert {:error, {:invalid_name, _sentence}} =
               Computers.rename(@loft, String.duplicate("a", 65), opts(Process.get(:fake_rows)))

      assert {:error, {:not_found, "Your Fermix has no such computer."}} =
               Computers.rename(
                 "11111111-2222-4333-8444-555555555555",
                 "spare",
                 opts(Process.get(:fake_rows))
               )
    end
  end

  describe "the prompt section" do
    @host %{
      install: :general,
      os: :linux,
      os_version: "Debian 13",
      architecture: "x86_64",
      linux_app: false
    }
    @zone [personalization: [timezone: "America/New_York"]]

    test "lists this server, then each computer by name with its state and offers" do
      rows = [
        row(@studio, "studio Mac", "macos", connected: true, since: @since),
        row(@loft, "loft Linux", "linux")
      ]

      live = %{@studio => %{offers: [@files, @history_off], path: :direct, since: @since}}
      records = %{@loft => %{seen_at: @seen, offers: [@files, @shell]}}

      section =
        Computers.prompt_section(
          opts(rows, live: live, records: records, always_on: true, host_facts: @host) ++ @zone
        )

      assert section == """
             ## Computers
             - This server: Debian 13. Files, shell and a headless browser run here by default.
             - loft Linux (Linux, away, last seen Friday, May 30, 2031 at 10:14 PM EDT): files, shell (strict).
             - studio Mac (macOS, connected): files.\
             """

      refute section =~ @studio
      refute section =~ @loft
    end

    test "says nothing on a guest's turn, without Always On, off the primary, or with no computer" do
      rows = [row(@loft, "loft Linux", "linux")]
      base = opts(rows, always_on: true, host_facts: @host)

      assert is_binary(Computers.prompt_section(base))
      assert Computers.prompt_section([trust: :guest] ++ base) == nil
      assert Computers.prompt_section(Keyword.put(base, :always_on, false)) == nil
      assert Computers.prompt_section(Keyword.put(base, :role, :device)) == nil
      assert Computers.prompt_section(opts([], always_on: true, host_facts: @host)) == nil
    end
  end
end
