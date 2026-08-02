defmodule FermixCore.Acp.IdentityStoreTest do
  # async: false — one test mutates FERMIX_HOME, and the consent-line assertions
  # capture the global Logger. Every other test is scoped to its own tmp dir.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FermixCore.Acp.Identity
  alias FermixCore.Acp.IdentityStore
  alias FermixTestSupport.SafeRm

  # Published NIP-19 vector (see nostr/key_test.exs for its derivation).
  @nsec "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
  @public_hex "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
  @npub "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

  setup do
    # The consent line is Logger.info and config/test.exs pins the primary level
    # to :warning, which drops it before any capture handler sees it. Establish
    # the precondition here rather than assuming it, and put it back after.
    previous_level = Logger.level()
    Logger.configure(level: :info)

    root = SafeRm.make_tmp_dir!("acp-identity-store")

    on_exit(fn ->
      Logger.configure(level: previous_level)
      SafeRm.rm_rf!(root)
    end)

    {:ok, dir: Path.join(root, "acp_identities")}
  end

  defp fixture(seed, overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    struct!(
      %Identity{
        id: :sha256 |> :crypto.hash("fermix-acp-#{seed}") |> Base.encode16(case: :lower),
        kind: :buzz,
        display_name: "agent-#{seed}",
        relay_url: "wss://relay.example.test",
        auth_tag: "tag-#{seed}",
        path: "/opt/buzz/bin:/usr/bin",
        git_config: %{"GIT_TERMINAL_PROMPT" => "0", "GIT_CONFIG_COUNT" => "0"},
        secrets: %{"BUZZ_PRIVATE_KEY" => "nsec-fixture-#{seed}"},
        first_seen: now,
        last_seen: now
      },
      overrides
    )
  end

  defp record_path(dir, %Identity{id: id}), do: Path.join(dir, "#{id}.json")

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  describe "upsert/2 and fetch/2" do
    test "round-trips a record built from a real hello env", %{dir: dir} do
      identity =
        Identity.new(%{
          "BUZZ_PRIVATE_KEY" => @nsec,
          "BUZZ_RELAY_URL" => "wss://relay.example.test",
          "BUZZ_ACP_DISPLAY_NAME" => "Fermix",
          "GIT_CONFIG_COUNT" => "1",
          "GIT_CONFIG_KEY_0" => "credential.helper",
          "GIT_CONFIG_VALUE_0" => "!buzz git-credential",
          "PATH" => "/opt/buzz/bin",
          "OPENAI_API_KEY" => "sk-operator"
        })

      assert {:ok, :created} = IdentityStore.upsert(identity, dir)
      assert {:ok, stored} = IdentityStore.fetch(@public_hex, dir)

      assert stored == identity
      assert Identity.to_env(stored) == Identity.to_env(identity)
      assert Identity.posting_capable?(Identity.to_env(stored))
    end

    test "creates the directory 0700 and the record 0600", %{dir: dir} do
      identity = fixture("perms")

      assert {:ok, :created} = IdentityStore.upsert(identity, dir)
      assert mode(dir) == 0o700
      assert mode(record_path(dir, identity)) == 0o600
    end

    test "a missing record is named, not an empty success", %{dir: dir} do
      assert {:error, {:identity_missing, @public_hex, path}} =
               IdentityStore.fetch(@public_hex, dir)

      assert path == Path.join(dir, "#{@public_hex}.json")
    end

    test "an unusable store directory is named, so the Peer can downgrade", %{dir: dir} do
      # A plain file where the directory belongs — deterministic, and unlike a
      # chmod it still blocks when the suite happens to run as root.
      File.write!(dir, "")

      assert {:error, {:identity_dir_unwritable, ^dir, _reason}} =
               IdentityStore.upsert(fixture("no-dir"), dir)
    end

    test "an id that is not a public key is refused before any path is built", %{dir: dir} do
      assert {:error, {:invalid_identity_id, "../../etc/passwd"}} =
               IdentityStore.fetch("../../etc/passwd", dir)

      assert {:error, {:invalid_identity_id, "short"}} = IdentityStore.forget("short", dir)
    end
  end

  describe "upsert/2 — consent, exactly once" do
    test "the first persist logs one line naming kind, npub and path", %{dir: dir} do
      identity = Identity.new(%{"BUZZ_PRIVATE_KEY" => @nsec, "PATH" => "/opt/buzz/bin"})

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :created} = IdentityStore.upsert(identity, dir)
        end)

      assert log =~ "buzz"
      assert log =~ @npub
      assert log =~ record_path(dir, identity)
      refute log =~ @nsec
    end

    # Deterministic for an atomic create; only probabilistic against a broken
    # one — an exists-then-write implementation loses this race often, not
    # always (measured: caught roughly one run in three). It is a regression
    # probe, not a proof of atomicity; the proof is `:file.make_link/2` itself.
    test "ten simultaneous identical first presentations log exactly once", %{dir: dir} do
      identity = fixture("pool")

      log =
        capture_log([level: :info], fn ->
          results = race(List.duplicate(identity, 10), &IdentityStore.upsert(&1, dir))

          assert Enum.count(results, &(&1 == {:ok, :created})) == 1
          assert Enum.count(results, &(&1 == {:ok, :unchanged})) == 9
        end)

      consent_lines = log |> String.split("\n") |> Enum.filter(&(&1 =~ "IdentityStore"))
      assert length(consent_lines) == 1
    end

    test "K concurrent upserts of K distinct identities leave K records", %{dir: dir} do
      identities = Enum.map(1..16, &fixture("agent-#{&1}"))

      results = race(identities, &IdentityStore.upsert(&1, dir))

      assert Enum.all?(results, &(&1 == {:ok, :created}))
      assert length(IdentityStore.list(dir)) == 16

      for identity <- identities do
        assert {:ok, ^identity} = IdentityStore.fetch(identity.id, dir)
      end
    end
  end

  describe "upsert/2 — re-presentation" do
    test "an unchanged re-presentation writes nothing and logs nothing", %{dir: dir} do
      identity = fixture("stable")
      assert {:ok, :created} = IdentityStore.upsert(identity, dir)

      path = record_path(dir, identity)
      before_stat = File.stat!(path, time: :posix)
      before_content = File.read!(path)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, :unchanged} = IdentityStore.upsert(identity, dir)
        end)

      assert File.read!(path) == before_content
      after_stat = File.stat!(path, time: :posix)
      assert after_stat.mtime == before_stat.mtime
      # A rename would mint a new inode; an untouched record keeps its own.
      assert after_stat.inode == before_stat.inode
      refute log =~ "IdentityStore"
    end

    test "a changed re-presentation replaces the record and preserves first_seen", %{dir: dir} do
      original = fixture("rotating")
      assert {:ok, :created} = IdentityStore.upsert(original, dir)

      later = DateTime.add(original.last_seen, 60, :second)

      moved = %{
        original
        | relay_url: "wss://moved.example.test",
          path: "/new/buzz/bin",
          first_seen: later,
          last_seen: later
      }

      assert {:ok, :updated} = IdentityStore.upsert(moved, dir)
      assert {:ok, stored} = IdentityStore.fetch(original.id, dir)

      assert stored.first_seen == original.first_seen
      assert stored.last_seen == later
      assert stored.relay_url == "wss://moved.example.test"
      assert stored.path == "/new/buzz/bin"
    end

    test "a wholesale replacement drops fields the new presentation omits", %{dir: dir} do
      original = fixture("wholesale")
      assert {:ok, :created} = IdentityStore.upsert(original, dir)

      stripped = %{original | auth_tag: nil, git_config: %{}}
      assert {:ok, :updated} = IdentityStore.upsert(stripped, dir)

      assert {:ok, stored} = IdentityStore.fetch(original.id, dir)
      assert stored.auth_tag == nil
      assert stored.git_config == %{}
    end

    test "a leftover temp file is never mistaken for a record", %{dir: dir} do
      identity = fixture("tmp-noise")
      assert {:ok, :created} = IdentityStore.upsert(identity, dir)
      File.write!(Path.join(dir, "#{identity.id}.json.tmp.99"), "junk")

      assert length(IdentityStore.list(dir)) == 1
    end
  end

  describe "fetch/2 — the three read-failure kinds stay distinct" do
    test "a corrupt record is quarantined, refused loudly, and never reset", %{dir: dir} do
      identity = fixture("corrupt")
      assert {:ok, :created} = IdentityStore.upsert(identity, dir)
      path = record_path(dir, identity)
      File.write!(path, ~s({"version": 1, "id": "trunc))

      log =
        capture_log(fn ->
          assert {:error, {:identity_quarantined, id, ^path, backup, reason}} =
                   IdentityStore.fetch(identity.id, dir)

          assert id == identity.id
          assert backup =~ ".broken."
          assert File.read!(backup) == ~s({"version": 1, "id": "trunc)
          assert mode(backup) == 0o600
          # The refusal must never carry the record's own bytes.
          refute inspect(reason) =~ "trunc"
        end)

      assert log =~ "preserved at"
      refute File.exists?(path)
    end

    test "a world-readable record is refused with the chmod line", %{dir: dir} do
      identity = fixture("loose-perms")
      assert {:ok, :created} = IdentityStore.upsert(identity, dir)
      path = record_path(dir, identity)
      File.chmod!(path, 0o644)

      log =
        capture_log(fn ->
          assert {:error, {:identity_permissions, _id, ^path, 0o644}} =
                   IdentityStore.fetch(identity.id, dir)
        end)

      assert log =~ "chmod 600 #{path}"
      # Refused, not repaired and not deleted.
      assert File.exists?(path)
      assert mode(path) == 0o644
    end

    test "a record from an unsupported version is refused without quarantining", %{dir: dir} do
      identity = fixture("future")
      assert {:ok, :created} = IdentityStore.upsert(identity, dir)
      path = record_path(dir, identity)
      File.write!(path, Jason.encode!(%{"version" => 99, "id" => identity.id, "kind" => "buzz"}))

      assert {:error, {:identity_unsupported, _id, ^path, {:version, 99}}} =
               IdentityStore.fetch(identity.id, dir)

      assert File.exists?(path)
    end

    test "a record whose stored id disagrees with its filename is quarantined", %{dir: dir} do
      identity = fixture("mismatch")
      assert {:ok, :created} = IdentityStore.upsert(identity, dir)
      other = fixture("elsewhere")
      path = record_path(dir, identity)

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "id" => other.id,
          "kind" => "buzz",
          "first_seen" => DateTime.to_iso8601(identity.first_seen),
          "last_seen" => DateTime.to_iso8601(identity.last_seen)
        })
      )

      capture_log(fn ->
        assert {:error, {:identity_quarantined, _id, ^path, _backup, {:id_mismatch, _stored}}} =
                 IdentityStore.fetch(identity.id, dir)
      end)
    end
  end

  describe "list/1" do
    test "is the honest empty result before anything connects", %{dir: dir} do
      assert IdentityStore.list(dir) == []
    end

    test "reports failures alongside readable records rather than dropping them", %{dir: dir} do
      good = fixture("good")
      bad = fixture("bad")
      assert {:ok, :created} = IdentityStore.upsert(good, dir)
      assert {:ok, :created} = IdentityStore.upsert(bad, dir)
      File.chmod!(record_path(dir, bad), 0o644)

      results = with_quiet_log(fn -> IdentityStore.list(dir) end)

      assert {:ok, good} in results
      assert Enum.any?(results, &match?({:error, {:identity_permissions, _, _, _}}, &1))
      assert length(results) == 2
    end
  end

  describe "forget/2 and forget_all/1" do
    test "forget removes exactly one record", %{dir: dir} do
      keep = fixture("keep")
      drop = fixture("drop")
      assert {:ok, :created} = IdentityStore.upsert(keep, dir)
      assert {:ok, :created} = IdentityStore.upsert(drop, dir)

      assert :ok = IdentityStore.forget(drop.id, dir)

      refute File.exists?(record_path(dir, drop))
      assert {:ok, ^keep} = IdentityStore.fetch(keep.id, dir)
      assert {:error, {:identity_missing, _id, _path}} = IdentityStore.fetch(drop.id, dir)
    end

    test "forgetting an absent record is named, not silently fine", %{dir: dir} do
      assert {:error, {:identity_missing, _id, _path}} =
               IdentityStore.forget(fixture("ghost").id, dir)
    end

    test "forget_all clears every record and reports the count", %{dir: dir} do
      for seed <- 1..3, do: IdentityStore.upsert(fixture("all-#{seed}"), dir)

      assert {:ok, 3} = IdentityStore.forget_all(dir)
      assert IdentityStore.list(dir) == []
      assert {:ok, 0} = IdentityStore.forget_all(dir)
    end

    test "forget_all leaves quarantined evidence in place", %{dir: dir} do
      identity = fixture("evidence")
      assert {:ok, :created} = IdentityStore.upsert(identity, dir)
      File.write!(record_path(dir, identity), "{oops")
      capture_log(fn -> IdentityStore.fetch(identity.id, dir) end)

      assert {:ok, 0} = IdentityStore.forget_all(dir)
      assert dir |> File.ls!() |> Enum.any?(&(&1 =~ ".broken."))
    end
  end

  describe "dir/0" do
    test "resolves under FERMIX_HOME" do
      previous = System.get_env("FERMIX_HOME")
      home = SafeRm.make_tmp_dir!("acp-identity-home")

      on_exit(fn ->
        restore_home(previous)
        SafeRm.rm_rf!(home)
      end)

      System.put_env("FERMIX_HOME", home)
      assert IdentityStore.dir() == Path.join(home, "acp_identities")
    end
  end

  defp restore_home(nil), do: System.delete_env("FERMIX_HOME")
  defp restore_home(value), do: System.put_env("FERMIX_HOME", value)

  # Start `count` workers, hold them all at a barrier, then release them at
  # once — an exists-then-write implementation has to actually lose this race,
  # not merely be given the opportunity to.
  defp race(inputs, fun) when is_list(inputs) do
    starter = self()
    tasks = Enum.map(inputs, &start_worker(starter, fun, &1))

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5_000
    end

    for task <- tasks, do: send(task.pid, :go)

    Task.await_many(tasks, 5_000)
  end

  defp start_worker(starter, fun, input) do
    Task.async(fn ->
      send(starter, {:ready, self()})

      receive do
        :go -> fun.(input)
      after
        5_000 -> flunk("barrier never released")
      end
    end)
  end

  # Run `fun` with its (expected, asserted elsewhere) log output swallowed, and
  # hand back its return value.
  defp with_quiet_log(fun) do
    parent = self()
    capture_log(fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, result} -> result
    after
      0 -> flunk("the captured function returned nothing")
    end
  end
end
