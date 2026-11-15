defmodule FermixCore.Home.ComputerKeyTest do
  # M97 §7.5, D13: a linked computer's own key lives in the engine's secret
  # store, named by the home's profile, and `device/desktop.json` records
  # which store holds it. The stub keychain is one table for the VM, so every
  # home here names a profile of its own; two homes share one only where a
  # test is about that.
  use ExUnit.Case, async: true

  alias FermixCore.Home.ComputerKey
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Management.Copy
  alias FermixCore.Setup.SecretWriter
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.SecretWriterStub

  @item {:device_key, :desktop}

  # A store that answers as a locked login keyring does.
  defmodule LockedWriter do
    @moduledoc false
    @behaviour FermixCore.Setup.SecretWriter

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def probe(opts \\ []) do
      %{
        store: Keyword.fetch!(opts, :store),
        state: :locked,
        sentence: "the login keyring is locked: unlock it"
      }
    end

    @impl true
    def put(_key, _value, _opts \\ []), do: flunk("a locked store is written to")

    @impl true
    def get(_key, _opts \\ []), do: flunk("a locked store is read")

    @impl true
    def delete(_key, _opts \\ []), do: flunk("a locked store is deleted from")

    @impl true
    def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
  end

  # A store that takes the key and then will not give it back.
  defmodule NoReadBackWriter do
    @moduledoc false
    @behaviour FermixCore.Setup.SecretWriter

    alias FermixTestSupport.SecretWriterStub

    @impl true
    def available?(_opts \\ []), do: true

    @impl true
    def probe(opts \\ []), do: SecretWriterStub.probe(opts)

    @impl true
    def put(key, value, opts \\ []), do: SecretWriterStub.put(key, value, opts)

    @impl true
    def get(key, opts \\ []) do
      case SecretWriterStub.get(key, opts) do
        {:ok, _stored} -> {:error, {:helper_failed, "stub lookup", 1, "no answer"}}
        missing -> missing
      end
    end

    @impl true
    def delete(key, opts \\ []), do: SecretWriterStub.delete(key, opts)

    @impl true
    def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
  end

  # Stores that answer for an item they do not hold as the real helpers do,
  # never with `:missing_secret`: the Keychain's `security` exits 44
  # (errSecItemNotFound), and `secret-tool lookup` exits 1 and prints nothing.
  @absent_answers [
    {SecurityAnswers,
     {:helper_failed, "/usr/bin/security find-generic-password -a fermix -s item -g", 44,
      "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n"}},
    {SecretToolAnswers,
     {:helper_failed, "/usr/bin/secret-tool lookup service item account fermix", 1, ""}}
  ]

  for {name, absent} <- @absent_answers do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      @behaviour FermixCore.Setup.SecretWriter

      alias FermixTestSupport.SecretWriterStub

      @absent absent

      @impl true
      def available?(_opts \\ []), do: true

      @impl true
      def probe(opts \\ []), do: SecretWriterStub.probe(opts)

      @impl true
      def put(key, value, opts \\ []), do: SecretWriterStub.put(key, value, opts)

      @impl true
      def get(key, opts \\ []) do
        case SecretWriterStub.get(key, opts) do
          {:error, :missing_secret} -> {:error, @absent}
          answer -> answer
        end
      end

      @impl true
      def delete(key, opts \\ []), do: SecretWriterStub.delete(key, opts)

      @impl true
      def command_source(_key, _opts \\ []), do: %{source: :command, command: "", args: []}
    end
  end

  setup do
    tmp = SafeRm.make_tmp_dir!("computer_key")
    on_exit(fn -> SafeRm.rm_rf!(tmp) end)
    %{tmp: tmp, profile: "ck-#{System.unique_integer([:positive])}"}
  end

  describe "create" do
    test "makes a key in the home's own store, by its profile, and reads it back", ctx do
      home = home!(ctx, "mac")

      assert {:ok, %{private: private, public: public} = keypair, :keyring} =
               ComputerKey.create(home)

      assert {public, private} == :crypto.generate_key(:ecdh, :x25519, private)
      # One printable line: the keychain gives it back as it was written.
      assert stored(ctx.profile, :keyring) == {:ok, Base.encode64(private)}
      assert ComputerKey.read(home, store: :keyring) == {:ok, keypair}
    end

    test "a home on the file store keeps it in its secrets folder, closed to others", ctx do
      home = home!(ctx, "box", secret_store: "file")

      assert {:ok, keypair, :file} = ComputerKey.create(home, impl: SecretWriter.File)

      file = Path.join(home, "secrets/device.desktop_key")
      assert File.read!(file) == Base.encode64(keypair.private)
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
      assert ComputerKey.read(home, store: :file, impl: SecretWriter.File) == {:ok, keypair}
    end

    # A fresh keychain holds no item, and each helper says so in its own
    # way: a key is made all the same, and one that is gone reads as missing.
    for {name, _absent} <- @absent_answers do
      test "makes a key where #{inspect(name)} says the store holds none", ctx do
        home = home!(ctx, "mac")
        opts = [impl: Module.concat(__MODULE__, unquote(name))]

        assert {:ok, keypair, :keyring} = ComputerKey.create(home, opts)
        assert ComputerKey.read(home, [store: :keyring] ++ opts) == {:ok, keypair}

        assert ComputerKey.delete(home, :keyring, [public: keypair.public] ++ opts) == :ok
        assert ComputerKey.read(home, [store: :keyring] ++ opts) == {:error, {:missing, :keyring}}
        # Deleting what is gone is no refusal.
        assert ComputerKey.delete(home, :keyring, [public: keypair.public] ++ opts) == :ok
      end
    end

    test "any other helper failure is the store's refusal, not a missing key", ctx do
      home = home!(ctx, "mac")

      for reason <- [
            {:helper_failed, "/usr/bin/security find-generic-password -a fermix -s item -g", 51,
             "security: denied"},
            {:helper_failed, "/usr/bin/secret-tool lookup service item", 1,
             "secret-tool: Cannot autolaunch D-Bus without X11"},
            {:helper_timeout, "/usr/bin/security find-generic-password", 3_000}
          ] do
        refute SecretWriter.absent?(reason), inspect(reason)
      end

      assert SecretWriter.absent?(:missing_secret)
      assert {:ok, _keypair, :keyring} = ComputerKey.create(home)
    end

    test "never overwrites another computer key two homes under one profile share", ctx do
      first = home!(ctx, "first")
      second = home!(ctx, "second")
      {:ok, kept, :keyring} = ComputerKey.create(first)

      assert ComputerKey.create(second) == {:error, {:in_use, :keyring}}
      assert ComputerKey.read(first, store: :keyring) == {:ok, kept}
    end

    test "the key a caller already chose is stored once, and again is no refusal", ctx do
      home = home!(ctx, "mac")
      keypair = keypair()

      assert {:ok, ^keypair, :keyring} = ComputerKey.create(home, keypair: keypair)
      assert {:ok, ^keypair, :keyring} = ComputerKey.create(home, keypair: keypair)
    end

    test "refuses while the file an older Fermix kept the key in is still here", ctx do
      home = home!(ctx, "mac")
      legacy!(home, keypair().private)

      assert {:error, {:file_key, file}} = ComputerKey.create(home)
      assert file == Path.join(home, "device/desktop_key")
      assert stored(ctx.profile, :keyring) == {:error, :missing_secret}
    end

    test "a locked keyring is refused by name, before anything is stored", ctx do
      home = home!(ctx, "mac")

      assert {:error, {:unusable, %{state: :locked}} = reason} =
               ComputerKey.create(home, impl: LockedWriter)

      assert ComputerKey.error_sentence(reason) ==
               "Fermix cannot use this computer's key: the login keyring is locked: unlock it."
    end
  end

  describe "read" do
    test "reads from the store the link records", ctx do
      home = home!(ctx, "mac")
      {:ok, keypair, :keyring} = ComputerKey.create(home)
      link!(home, :keyring)

      assert ComputerKey.read(home) == {:ok, keypair}
    end

    test "a link from before the key moved is not read as a file", ctx do
      home = home!(ctx, "mac")
      v1_link!(home)
      legacy!(home, keypair().private)

      assert ComputerKey.read(home) == {:error, :not_moved}
    end

    test "names a store that holds no key, a home with no link and an item that is no key",
         ctx do
      home = home!(ctx, "mac")
      link!(home, :keyring)
      assert ComputerKey.read(home) == {:error, {:missing, :keyring}}

      :ok = SecretWriter.put(@item, "not a key", profile: ctx.profile, store: :keyring)
      assert ComputerKey.read(home) == {:error, {:invalid, :keyring}}

      unlinked = home!(ctx, "unlinked")
      path = DesktopLink.path(unlinked)
      assert ComputerKey.read(unlinked) == {:error, {:link, {:file, path, :enoent}}}
    end
  end

  describe "migrate" do
    test "moves the file's key into the store, records the store, then deletes the file", ctx do
      home = home!(ctx, "mac")
      %{private: private} = keypair = keypair()
      v1_link!(home)
      legacy!(home, private)

      assert ComputerKey.migrate(home) == :migrated

      assert {:ok, %{key: :keyring, device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e"}} =
               DesktopLink.read(home)

      refute File.exists?(legacy_path(home))
      assert stored(ctx.profile, :keyring) == {:ok, Base.encode64(private)}
      assert ComputerKey.read(home) == {:ok, keypair}
      assert ComputerKey.migrate(home) == :nothing
    end

    test "a home on the file store moves it into its secrets folder", ctx do
      home = home!(ctx, "box", secret_store: "file")
      keypair = keypair()
      v1_link!(home)
      legacy!(home, keypair.private)

      assert ComputerKey.migrate(home, impl: SecretWriter.File) == :migrated

      assert {:ok, %{key: :file}} = DesktopLink.read(home)
      refute File.exists?(legacy_path(home))
      assert ComputerKey.read(home, impl: SecretWriter.File) == {:ok, keypair}
    end

    test "has nothing to move without a link, or once the file is gone", ctx do
      unlinked = home!(ctx, "unlinked")
      assert ComputerKey.migrate(unlinked) == :nothing

      home = home!(ctx, "mac")
      {:ok, _keypair, :keyring} = ComputerKey.create(home)
      link!(home, :keyring)
      assert ComputerKey.migrate(home) == :nothing
    end

    test "stopped once the key was stored, it finishes with the same key", ctx do
      home = home!(ctx, "mac")
      keypair = keypair()
      v1_link!(home)
      legacy!(home, keypair.private)
      put!(ctx.profile, keypair.private)

      assert ComputerKey.migrate(home) == :migrated

      assert {:ok, %{key: :keyring}} = DesktopLink.read(home)
      refute File.exists?(legacy_path(home))
      assert ComputerKey.read(home) == {:ok, keypair}
    end

    test "stopped once the link named the store, it deletes the file it left", ctx do
      home = home!(ctx, "mac")
      keypair = keypair()
      link!(home, :keyring)
      legacy!(home, keypair.private)
      put!(ctx.profile, keypair.private)

      assert ComputerKey.migrate(home) == :migrated

      refute File.exists?(legacy_path(home))
      assert ComputerKey.read(home) == {:ok, keypair}
    end

    test "a key the store will not give back leaves the file and the link as they were",
         ctx do
      home = home!(ctx, "mac")
      keypair = keypair()
      v1_link!(home)
      legacy!(home, keypair.private)

      assert ComputerKey.migrate(home, impl: NoReadBackWriter) ==
               {:error, {:read_back, :keyring}}

      assert {:ok, %{key: nil}} = DesktopLink.read(home)
      assert File.read!(legacy_path(home)) == keypair.private

      # The next start, the store answering again, finishes the move.
      assert ComputerKey.migrate(home) == :migrated
      assert ComputerKey.read(home) == {:ok, keypair}
    end

    test "never overwrites another computer key under the same profile", ctx do
      other = home!(ctx, "other")
      {:ok, kept, :keyring} = ComputerKey.create(other)

      home = home!(ctx, "mac")
      v1_link!(home)
      legacy!(home, keypair().private)

      assert ComputerKey.migrate(home) == {:error, {:in_use, :keyring}}

      assert {:ok, %{key: nil}} = DesktopLink.read(home)
      assert File.exists?(legacy_path(home))
      assert ComputerKey.read(other, store: :keyring) == {:ok, kept}
    end

    test "a locked keyring changes nothing and says so", ctx do
      home = home!(ctx, "mac")
      v1_link!(home)
      legacy!(home, keypair().private)

      assert {:error, {:unusable, %{state: :locked}}} =
               ComputerKey.migrate(home, impl: LockedWriter)

      assert {:ok, %{key: nil}} = DesktopLink.read(home)
      assert File.exists?(legacy_path(home))
    end

    test "a key file readable by others, or none at all, is refused by name", ctx do
      home = home!(ctx, "mac")
      v1_link!(home)
      file = legacy_path(home)

      assert ComputerKey.migrate(home) == {:error, {:file, file, :enoent}}

      legacy!(home, keypair().private, 0o644)
      assert {:error, {:key_mode, ^file, 0o644} = reason} = ComputerKey.migrate(home)

      assert ComputerKey.error_sentence(reason) ==
               "This computer's key file is mode 0644, readable by others; Fermix uses it " <>
                 "only at 0600."

      File.write!(file, "short")
      File.chmod!(file, 0o600)
      assert ComputerKey.migrate(home) == {:error, {:invalid_key, file, :length}}
      assert stored(ctx.profile, :keyring) == {:error, :missing_secret}
    end
  end

  describe "delete" do
    test "deletes the stored key and any file an older Fermix left", ctx do
      home = home!(ctx, "mac")
      {:ok, _keypair, :keyring} = ComputerKey.create(home)
      legacy!(home, keypair().private)

      assert ComputerKey.delete(home, :keyring) == :ok

      assert stored(ctx.profile, :keyring) == {:error, :missing_secret}
      refute File.exists?(legacy_path(home))
      assert ComputerKey.delete(home, :keyring) == :ok
    end

    test "given the key it made, leaves another computer's key where it is", ctx do
      other = home!(ctx, "other")
      {:ok, kept, :keyring} = ComputerKey.create(other)
      home = home!(ctx, "mac")

      assert ComputerKey.delete(home, :keyring, public: keypair().public) == :ok
      assert ComputerKey.read(other, store: :keyring) == {:ok, kept}

      assert ComputerKey.delete(other, :keyring, public: kept.public) == :ok
      assert stored(ctx.profile, :keyring) == {:error, :missing_secret}
    end

    test "with no store recorded, only the file goes", ctx do
      home = home!(ctx, "mac")
      {:ok, kept, :keyring} = ComputerKey.create(home)
      legacy!(home, keypair().private)

      assert ComputerKey.delete(home, nil) == :ok

      refute File.exists?(legacy_path(home))
      assert ComputerKey.read(home, store: :keyring) == {:ok, kept}
    end

    test "a home on the file store loses the file", ctx do
      home = home!(ctx, "box", secret_store: "file")
      {:ok, _keypair, :file} = ComputerKey.create(home, impl: SecretWriter.File)

      assert ComputerKey.delete(home, :file, impl: SecretWriter.File) == :ok
      refute File.exists?(Path.join(home, "secrets/device.desktop_key"))
    end
  end

  describe "the item" do
    test "is named by profile in both OS stores and as a file of the file store" do
      assert SecretWriter.item_name(@item) == "device:desktop_key"
      assert SecretWriter.File.file_name(@item) == "device.desktop_key"

      assert service(SecretWriter.MacOS.delete_command(@item, profile: "general")) ==
               "fermix:device:desktop_key"

      assert service(SecretWriter.MacOS.delete_command(@item, profile: "fermix-dev")) ==
               "fermix:fermix-dev:device:desktop_key"

      assert SecretWriter.SecretTool.clear_command(@item, profile: "fermix-dev") ==
               ~w(clear service fermix:fermix-dev account fermix env device:desktop_key)
    end

    # The keychain prints a value of printable bytes in quotes and any other
    # value as bare hex (`security -g`): the key is one base64 line, so it
    # reads back as it was written. Only the command runner stands in.
    test "round-trips through the macOS writer as one printable line" do
      keychain = start_supervised!({Agent, fn -> nil end})
      value = Base.encode64(keypair().private)

      runner = fn "/usr/bin/security", args, _opts ->
        case args do
          ["add-generic-password" | _rest] ->
            Agent.update(keychain, fn _old -> flag(args, "-w") end)
            {:ok, %{exit: 0, stdout: "", truncated?: false}}

          ["delete-generic-password" | _rest] ->
            {:ok, %{exit: 44, stdout: "", truncated?: false}}

          ["find-generic-password" | _rest] ->
            assert "-g" in args
            stored = Agent.get(keychain, & &1)
            {:ok, %{exit: 0, stdout: ~s(password: "#{stored}"\n), truncated?: false}}
        end
      end

      opts = [
        profile: "fermix-dev",
        find_executable: fn "security" -> "/usr/bin/security" end,
        command_runner: runner
      ]

      assert SecretWriter.MacOS.put(@item, value, opts) == :ok
      assert SecretWriter.MacOS.get(@item, opts) == {:ok, value}
    end
  end

  test "every refusal is a sentence the copy rules pass", ctx do
    path = Path.join(ctx.tmp, "device/desktop_key")
    locked = %{store: :keyring, state: :locked, sentence: "the login keyring is locked"}

    reasons = [
      :not_moved,
      {:missing, :keyring},
      {:missing, :file},
      {:in_use, :keyring},
      {:in_use, :file},
      {:unusable, locked},
      {:store, :keyring, {:helper_timeout, "/usr/bin/security", 3_000}},
      {:store, :keyring, {:helper_failed, "/usr/bin/security", 51, "denied"}},
      {:store, :file, {:file_store, :eacces}},
      {:store, :keyring, :unavailable},
      {:read_back, :keyring},
      {:invalid, :file},
      {:file_key, path},
      {:file, path, :enoent},
      {:file, path, :eacces},
      {:key_mode, path, 0o644},
      {:invalid_key, path, :length},
      {:config, {:file, Path.join(ctx.tmp, "config.toml"), :eacces}},
      {:config, "[fermix_core] secret_store must be \"keyring\" or \"file\""},
      {:link, {:invalid_link, DesktopLink.path(ctx.tmp), :key}}
    ]

    for reason <- reasons do
      sentence = ComputerKey.error_sentence(reason)
      assert is_binary(sentence) and sentence != "", inspect(reason)
      assert Copy.violations(sentence, :prose, ["Fermix"]) == [], sentence
    end
  end

  # -- homes -----------------------------------------------------------------

  defp home!(ctx, name, opts \\ []) do
    home = Path.join(ctx.tmp, name)
    File.mkdir!(home)
    store = Keyword.get(opts, :secret_store)
    store_line = if store, do: ~s(secret_store = "#{store}"\n), else: ""

    File.write!(
      Path.join(home, "config.toml"),
      ~s([fermix_core]\nprofile = "#{ctx.profile}"\n) <> store_line
    )

    home
  end

  defp keypair do
    {public, private} = :crypto.generate_key(:ecdh, :x25519)
    %{private: private, public: public}
  end

  defp put!(profile, private),
    do: :ok = SecretWriter.put(@item, Base.encode64(private), profile: profile, store: :keyring)

  defp stored(profile, store), do: SecretWriterStub.get(@item, profile: profile, store: store)

  defp legacy_path(home), do: Path.join(home, "device/desktop_key")

  defp legacy!(home, private, mode \\ 0o600) do
    file = legacy_path(home)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, private)
    File.chmod!(file, mode)
  end

  defp link!(home, store), do: :ok = DesktopLink.write(home, Map.put(link(), :key, store))

  # A link an older Fermix wrote: version 1, the key in its own file.
  defp v1_link!(home) do
    %{primary: primary} = link = link()

    json = %{
      "v" => 1,
      "device_id" => link.device_id,
      "primary" => %{
        "name" => primary.name,
        "gateway_pk" => Base.encode64(primary.gateway_pk),
        "node_id" => primary.node_id,
        "relays" => primary.relays,
        "relays_rev" => primary.relays_rev
      },
      "primary_epoch" => link.epoch
    }

    file = DesktopLink.path(home)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Jason.encode!(json))
    File.chmod!(file, 0o600)
  end

  defp link do
    %{
      device_id: "6f1e2d3c-4b5a-4968-8778-695a4b3c2d1e",
      primary: %{
        name: "north-box",
        gateway_pk: :binary.copy(<<3>>, 32),
        node_id: String.duplicate("c4", 32),
        relays: [%{"url" => "https://eu1.relay.invalid/", "quic_port" => 7842}],
        relays_rev: String.duplicate("a1", 8)
      },
      epoch: 5
    }
  end

  defp service(args), do: flag(args, "-s")

  defp flag(args, name) do
    args |> Enum.drop_while(&(&1 != name)) |> Enum.at(1)
  end
end
