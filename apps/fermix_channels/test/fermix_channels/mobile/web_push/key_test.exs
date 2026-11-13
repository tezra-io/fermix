defmodule FermixChannels.Mobile.WebPush.KeyTest do
  use ExUnit.Case, async: true

  alias FermixChannels.Mobile.Identity
  alias FermixChannels.Mobile.WebPush.Key
  alias FermixChannels.Mobile.WebPush.Vapid
  alias FermixCore.Home.DeviceLocal
  alias FermixTestSupport.SafeRm

  setup do
    root = SafeRm.make_tmp_dir!("webpush-key")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    %{
      root: root,
      dir: Path.join(root, "mobile"),
      path: Path.join([root, "mobile", "webpush_key"])
    }
  end

  defp mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o777)

  defp temp_files(dir), do: Path.wildcard(Path.join(dir, "webpush_key.tmp.*"))

  defp write_key_file!(dir, path, contents) do
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  describe "ensure/1" do
    test "creates the key once, beside the phone channel's identity, 0600 in a 0700 directory",
         %{root: root, dir: dir, path: path} do
      assert {:ok, %Key{private: private, public: public} = key} = Key.ensure(root: root)

      assert {:ok, %{dir: ^dir}} = Identity.paths(root: root)
      assert File.read!(path) == private
      assert byte_size(private) == 32
      assert {:ok, ^public} = Vapid.public_key(private)
      assert mode(path) == 0o600
      assert mode(dir) == 0o700
      assert temp_files(dir) == []

      assert {:ok, ^key} = Key.ensure(root: root)
      assert {:ok, ^key} = Key.load(root: root)
    end

    test "keeps a directory the identity already made", %{root: root, dir: dir} do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      File.write!(Path.join(dir, "gateway_key"), :binary.copy(<<7>>, 32))

      assert {:ok, %Key{}} = Key.ensure(root: root)
      assert File.read!(Path.join(dir, "gateway_key")) == :binary.copy(<<7>>, 32)
    end

    test "a file that is not a key is an error, and is left exactly as it is",
         %{root: root, dir: dir, path: path} do
      write_key_file!(dir, path, "not a key\n")

      assert {:error, {:invalid_webpush_key, ^path, :invalid_length}} = Key.ensure(root: root)
      assert {:error, {:invalid_webpush_key, ^path, :invalid_length}} = Key.load(root: root)
      assert File.read!(path) == "not a key\n"
      assert mode(path) == 0o600
    end

    test "a scalar outside the curve's order is an error, and is left as it is",
         %{root: root, dir: dir, path: path} do
      write_key_file!(dir, path, <<0::256>>)

      assert {:error, {:invalid_webpush_key, ^path, :out_of_range}} = Key.ensure(root: root)
      assert File.read!(path) == <<0::256>>
    end

    test "a key file readable by others is refused, not used or replaced",
         %{root: root, dir: dir, path: path} do
      {:ok, %Key{private: private}} = Key.ensure(root: root)
      File.chmod!(path, 0o644)

      assert {:error, {:unsafe_permissions, ^path, 0o644, 0o600}} = Key.ensure(root: root)
      assert File.read!(path) == private
      assert temp_files(dir) == []
    end

    test "a directory others can enter is refused before anything is written",
         %{root: root, dir: dir, path: path} do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o755)

      assert {:error, {:unsafe_permissions, ^dir, 0o755, 0o700}} = Key.ensure(root: root)
      refute File.exists?(path)
    end

    test "a link where the key belongs is refused", %{root: root, dir: dir, path: path} do
      target = Path.join(root, "elsewhere")
      write_key_file!(dir, target, :binary.copy(<<1>>, 32))
      File.ln_s!(target, path)

      assert {:error, {:unsafe_file_type, ^path, :symlink}} = Key.ensure(root: root)
    end

    test "two ensures racing to create the key end with one key, the one on disk",
         %{root: root, dir: dir, path: path} do
      test_pid = self()

      # Both callers have found no key and written their own before either
      # publishes; then the first publishes and returns before the second
      # does. A publish that replaces (a rename) would hand the two callers
      # different keys.
      barrier_link = fn temp, final ->
        send(test_pid, {:ready, self()})

        receive do
          :go -> File.ln(temp, final)
        after
          10_000 -> {:error, :barrier_timeout}
        end
      end

      first = Task.async(fn -> Key.ensure(root: root, link: barrier_link) end)
      second = Task.async(fn -> Key.ensure(root: root, link: barrier_link) end)

      assert_receive {:ready, ready_one}
      assert_receive {:ready, ready_other}
      assert Enum.sort([ready_one, ready_other]) == Enum.sort([first.pid, second.pid])
      assert length(temp_files(dir)) == 2

      send(first.pid, :go)
      assert {:ok, key} = Task.await(first, 10_000)
      send(second.pid, :go)
      assert {:ok, ^key} = Task.await(second, 10_000)

      assert File.read!(path) == key.private
      assert temp_files(dir) == []
    end

    test "a caller that loses the race returns the winner's key and removes its own",
         %{root: root, dir: dir, path: path} do
      {winner_public, winner_private} = :crypto.generate_key(:ecdh, :secp256r1)

      lose = fn temp, final ->
        File.write!(final, winner_private)
        File.chmod!(final, 0o600)
        File.ln(temp, final)
      end

      assert {:ok, %Key{private: ^winner_private, public: ^winner_public}} =
               Key.ensure(root: root, link: lose)

      assert File.read!(path) == winner_private
      assert temp_files(dir) == []
    end

    test "many concurrent ensures agree on one key", %{root: root, path: path} do
      results =
        1..8
        |> Enum.map(fn _ -> Task.async(fn -> Key.ensure(root: root) end) end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert [{:ok, key}] = Enum.uniq(results)
      assert File.read!(path) == key.private
    end

    test "a left-over temp file from an interrupted write does not stop creation",
         %{root: root, dir: dir} do
      write_key_file!(dir, Path.join(dir, "webpush_key.tmp.left-over"), "partial")

      assert {:ok, %Key{}} = Key.ensure(root: root)
    end

    test "unknown options are refused", %{root: root} do
      assert {:error, {:unknown_options, [:dir]}} = Key.ensure(root: root, dir: "/tmp")
      assert {:error, {:invalid_option, :link}} = Key.ensure(root: root, link: :rename)
    end
  end

  describe "load/1" do
    test "answers :absent and creates nothing when there is no key",
         %{root: root, dir: dir} do
      assert {:error, :absent} = Key.load(root: root)
      refute File.exists?(dir)
    end
  end

  describe "public_text/1" do
    test "is the point in base64url without padding, as the phone hands it to Play services",
         %{root: root} do
      {:ok, %Key{public: public} = key} = Key.ensure(root: root)
      text = Key.public_text(key)

      assert byte_size(text) == 87
      assert text =~ ~r/\A[A-Za-z0-9_-]{87}\z/
      assert Base.url_decode64!(text, padding: false) == public
    end
  end

  test "inspecting a key never shows the private scalar", %{root: root} do
    {:ok, %Key{private: private} = key} = Key.ensure(root: root)

    refute inspect(key) =~ "private"
    refute inspect(key, limit: :infinity) =~ inspect(private, limit: :infinity)
  end

  # The home archive (`FermixCore.Home.Archive`) carries every file under the
  # home except `DeviceLocal`'s list: the key moves with the home, an
  # interrupted write of it does not.
  test "the key travels with the home and an interrupted write of it stays behind" do
    refute DeviceLocal.excluded?("mobile/webpush_key")
    assert DeviceLocal.excluded?("mobile/webpush_key.tmp.AbC-12_x")
  end
end
