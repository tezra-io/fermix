defmodule FermixCore.Sandbox.LandlockTest do
  # Pure: the rules are carved from a fake tree, so nothing here reads the host.
  use ExUnit.Case, async: true

  alias FermixCore.Sandbox.Landlock

  @home "/home/owner"
  @fermix "/home/owner/.fermix"
  @workspace "/home/owner/.fermix/workspace"
  @skills "/home/owner/.fermix/skills"

  # Directories end in "/", `{path, type}` names anything else; every folder
  # above an entry exists.
  @tree [
    {"/bin", :symlink},
    "/usr/bin/sh",
    "/etc/hostname",
    {"/dev/null", :other},
    {"/dev/tty", :other},
    "/dev/pts/",
    {"/dev/ptmx", :symlink},
    "/tmp/build/",
    "/run/user/",
    "/run/fermix/enroll.code",
    "/home/owner/Documents/note.txt",
    "/home/owner/.ssh/id_probe",
    "/home/owner/.config/gcloud/credentials.db",
    "/home/owner/.config/gcloud/credentials.db-wal",
    "/home/owner/.config/gcloud/configurations/",
    "/home/owner/.fermix/config.toml",
    "/home/owner/.fermix/auth.json",
    "/home/owner/.fermix/auth.json.tmp.1",
    "/home/owner/.fermix/secrets/KEY",
    "/home/owner/.fermix/secrets/.staging-1/secret",
    "/home/owner/.fermix/mobile/gateway_key",
    "/home/owner/.fermix/mobile/iroh_key",
    "/home/owner/.fermix/device/desktop_key",
    "/home/owner/.fermix/workspace/",
    "/home/owner/.fermix/skills/",
    "/home/owner/.fermix/plugins/probe/tool",
    "/home/owner/.fermix/plugins/run/token",
    {"/home/owner/.fermix/daemon.sock", :other}
  ]

  defp fs(entries \\ @tree, opts \\ []) do
    types = Enum.reduce(entries, %{"/" => :directory}, &add_entry/2)
    unlistable = Keyword.get(opts, :unlistable, [])

    %{
      list: fn dir ->
        if dir in unlistable,
          do: {:error, :eacces},
          else:
            {:ok,
             for(
               path <- Map.keys(types),
               path != "/",
               Path.dirname(path) == dir,
               do: Path.basename(path)
             )}
      end,
      type: fn path -> Map.get(types, path, :missing) end
    }
  end

  defp add_entry({path, type}, types), do: types |> with_parents(path) |> Map.put(path, type)

  defp add_entry(path, types) do
    if String.ends_with?(path, "/") do
      dir = String.trim_trailing(path, "/")
      types |> with_parents(dir) |> Map.put(dir, :directory)
    else
      types |> with_parents(path) |> Map.put(path, :regular)
    end
  end

  defp with_parents(types, path) do
    path
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.take_while(&(&1 != "/"))
    |> Enum.reduce(types, &Map.put(&2, &1, :directory))
  end

  defp input(mode) do
    owner_credentials = [
      {"#{@home}/.ssh", :named},
      {"#{@home}/.config/gcloud/credentials.db", :named}
    ]

    unreadable =
      [
        {"#{@fermix}/secrets", :tree},
        {"#{@fermix}/mobile", :tree},
        {"#{@fermix}/device", :tree},
        {"#{@fermix}/plugins/run", :tree},
        {"/run/fermix", :tree},
        {"#{@fermix}/auth.json", :prefix}
      ] ++ if(mode == :open, do: [], else: owner_credentials)

    %{
      writable:
        if(mode == :open, do: ["/", @workspace, @skills, "/tmp"], else: [@workspace, "/tmp"]),
      fermix_home: @fermix,
      fermix_writable: [@workspace, @skills],
      protected: ["/etc", "/usr", "#{@fermix}/config.toml", "#{@fermix}/secrets", "/run/fermix"],
      credentials: ["#{@home}/.ssh", "#{@home}/.config/gcloud/credentials.db"],
      unreadable: unreadable,
      no_exec: ["#{@fermix}/plugins"],
      devices: [{"/dev/null", "w"}, {"/dev/tty", "wi"}, {"/dev/ptmx", "wi"}, {"/dev/pts", "wi"}]
    }
  end

  defp fake_shim(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n#{body}\n")
    File.chmod!(path, 0o755)
    path
  end

  defp grants(mode, fs \\ fs()) do
    assert {:ok, grants} = Landlock.grants(input(mode), fs)
    assert grants == Enum.uniq_by(grants, &elem(&1, 0)), "a path has two rules"
    Map.new(grants)
  end

  # Whether any rule reaches `path`: one on it or on a folder above it.
  defp reached?(grants, path, letter) do
    Enum.any?(grants, fn {root, access} ->
      String.contains?(access, letter) and
        (path == root or String.starts_with?(path, root <> "/"))
    end)
  end

  describe "grants/2 in strict" do
    test "a protected path gets no rule: its folders above are carved and only listed" do
      grants = grants(:strict)

      for dir <- [
            "/",
            "/home",
            @home,
            @fermix,
            "#{@home}/.config",
            "#{@home}/.config/gcloud",
            "/run"
          ],
          do: assert(grants[dir] == "l", dir)

      for secret <- [
            "#{@fermix}/secrets/KEY",
            "#{@fermix}/auth.json",
            "#{@fermix}/auth.json.tmp.1",
            "#{@fermix}/mobile/gateway_key",
            "#{@fermix}/mobile/iroh_key",
            "#{@fermix}/device/desktop_key",
            "#{@fermix}/plugins/run/token",
            "/run/fermix/enroll.code",
            "#{@home}/.ssh/id_probe",
            "#{@home}/.config/gcloud/credentials.db",
            "#{@home}/.config/gcloud/credentials.db-wal"
          ] do
        refute reached?(grants, secret, "r"), secret
        refute reached?(grants, secret, "w"), secret
      end
    end

    test "everything else reads and runs; plugins read but never run" do
      grants = grants(:strict)

      assert grants["/usr"] == "xrl"
      assert grants["/etc"] == "xrl"
      assert grants["#{@home}/Documents"] == "xrl"
      assert grants["#{@home}/.config/gcloud/configurations"] == "xrl"
      assert grants["#{@fermix}/config.toml"] == "xrl"
      assert grants["/run/user"] == "xrl"
      assert grants["#{@fermix}/plugins"] == "l"
      assert grants["#{@fermix}/plugins/probe"] == "rl"
      refute reached?(grants, "#{@fermix}/plugins/probe/tool", "x")
    end

    test "only the workspace, the temp folder and the terminal devices are writable" do
      grants = grants(:strict)

      assert grants[@workspace] == "xrlwc"
      assert grants["/tmp"] == "xrlwc"
      assert grants[@skills] == "xrl"
      assert grants["/dev/null"] == "w"
      assert grants["/dev/pts"] == "wi"
      writable = for {path, access} <- grants, String.contains?(access, "c"), do: path
      assert Enum.sort(writable) == Enum.sort(["/tmp", @workspace])
    end

    # From ABI 5 the kernel refuses a device's ioctls wherever no rule grants
    # them: only the terminals take them, so a pty still works.
    test "only the terminal devices take ioctls" do
      for mode <- [:strict, :standard, :open] do
        grants = grants(mode)
        ioctl = for {path, access} <- grants, String.contains?(access, "i"), do: path

        assert Enum.sort(ioctl) == ["/dev/pts", "/dev/tty"], "#{mode}"
        assert grants["/dev/tty"] == "wi"
      end
    end

    test "symlinks, sockets and entries that are gone get no rule" do
      grants = grants(:strict)

      refute Map.has_key?(grants, "/bin")
      refute Map.has_key?(grants, "/dev/ptmx")
      refute Map.has_key?(grants, "#{@fermix}/daemon.sock")
    end

    # The secret writer stages a key being saved in the home's `secrets/`, so
    # nothing secret sits in a temp folder and the temp folder stays whole.
    test "a key staged for saving is held inside secrets/, and the temp folder stays whole" do
      for mode <- [:strict, :standard, :open] do
        grants = grants(mode)
        staged = "#{@fermix}/secrets/.staging-1/secret"

        for letter <- ~w(r w c), do: refute(reached?(grants, staged, letter), "#{mode} #{letter}")
        assert grants["/tmp"] == "xrlwc", "#{mode}"
      end
    end

    test "a name prefix carves its folder, a temp folder included" do
      prefixed = %{input(:strict) | unreadable: [{"/tmp/probe-key-", :prefix}]}
      assert {:ok, grants} = Landlock.grants(prefixed, fs(@tree ++ ["/tmp/probe-key-1/secret"]))
      grants = Map.new(grants)

      assert grants["/tmp"] == "l"
      assert grants["/tmp/build"] == "xrlwc"
      refute reached?(grants, "/tmp/probe-key-1/secret", "r")
    end

    test "a carve wider than the shim's arguments allow refuses" do
      crowd = for i <- 1..Landlock.max_rules(), do: "/tmp/job-#{i}/"
      prefixed = %{input(:strict) | unreadable: [{"/tmp/probe-key-", :prefix}]}

      assert {:error, {:too_many_rules, count, max}} =
               Landlock.grants(prefixed, fs(@tree ++ crowd))

      assert count > max
    end

    test "a folder that must be carved and cannot be listed refuses" do
      assert {:error, {:unlistable, @home, :eacces}} =
               Landlock.grants(input(:strict), fs(@tree, unlistable: [@home]))
    end
  end

  describe "grants/2 in open" do
    test "the whole filesystem is writable but the protected set and Fermix's home" do
      grants = grants(:open)

      assert grants["#{@home}/Documents"] == "xrlwc"
      assert grants["/run/user"] == "xrlwc"
      assert grants[@workspace] == "xrlwc"
      assert grants[@skills] == "xrlwc"

      for path <- [
            "/etc/hostname",
            "/usr/bin/sh",
            "#{@fermix}/config.toml",
            "/run/fermix/enroll.code"
          ],
          do: refute(reached?(grants, path, "w"), path)

      # Carved, so nothing new appears directly in them, and nothing renames them.
      for dir <- ["/", "/home", @home, @fermix, "/run"],
          do: refute(reached?(grants, dir, "c"), dir)
    end

    test "the owner's credentials are readable in open, never writable" do
      grants = grants(:open)

      assert reached?(grants, "#{@home}/.ssh/id_probe", "r")
      refute reached?(grants, "#{@home}/.ssh/id_probe", "w")
      refute reached?(grants, "#{@home}/.config/gcloud/credentials.db-wal", "w")
      assert grants["#{@home}/.config/gcloud/configurations"] == "wc"
      assert reached?(grants, "#{@home}/.config/gcloud/configurations", "r")
    end
  end

  describe "args/1, refusal/2 and describe/1" do
    test "one ACCESS:PATH argument per rule" do
      assert Landlock.args([{"/a b", "xrl"}, {"/w", "wc"}, {"/dev/pts", "wi"}]) ==
               ["xrl:/a b", "wc:/w", "wi:/dev/pts"]
    end

    test "the shim's own refusals are told apart from the command's" do
      assert Landlock.refusal(
               69,
               "fermix_landlock: Landlock ABI 2 is below 3 (Linux before 6.2)\n"
             ) ==
               "This computer can't sandbox commands (Landlock is unavailable), so Fermix won't run them: " <>
                 "Landlock ABI 2 is below 3 (Linux before 6.2)."

      assert Landlock.refusal(65, "fermix_landlock: /x is a symlink; rules name resolved paths\n") ==
               "The command could not start inside Fermix's sandbox: fermix_landlock: /x is a symlink; rules name resolved paths"

      assert Landlock.refusal(
               71,
               "fermix_landlock: cannot start a session of its own: Operation not permitted\n"
             ) ==
               "The command could not start inside Fermix's sandbox: fermix_landlock: cannot start a session of its own: Operation not permitted"

      assert Landlock.refusal(69, "the command's own output") == nil
      assert Landlock.refusal(1, "fermix_landlock: looks like it, exit says otherwise") == nil

      assert Landlock.refusal(127, "fermix_landlock: cannot run /nope: No such file or directory") ==
               nil
    end

    @tag :tmp_dir
    test "probe/1 reads the shim's own answer", %{tmp_dir: tmp_dir} do
      held = fake_shim(tmp_dir, "held", "echo 'fermix_landlock: abi 5'; exit 0")
      assert Landlock.probe(held) == {:ok, 5}

      floor = fake_shim(tmp_dir, "floor", "echo 'fermix_landlock: abi 3'; exit 0")
      assert Landlock.probe(floor) == {:ok, 3}

      old =
        fake_shim(
          tmp_dir,
          "old",
          "echo 'fermix_landlock: Landlock ABI 2 is below 3 (Linux before 6.2)' >&2; exit 69"
        )

      assert {:error, {:unavailable, line}} = Landlock.probe(old)
      assert line == "fermix_landlock: Landlock ABI 2 is below 3 (Linux before 6.2)"

      # A shim that says it holds commands below the floor contradicts itself:
      # ABI 2 cannot refuse a truncate, so it is not taken at its word.
      for abi <- [1, 2] do
        odd = fake_shim(tmp_dir, "odd#{abi}", "echo 'fermix_landlock: abi #{abi}'; exit 0")
        assert {:error, {:failed, 0, _line}} = Landlock.probe(odd), "abi #{abi}"
      end

      stuck = fake_shim(tmp_dir, "stuck", "exit 0")
      File.chmod!(stuck, 0o644)
      assert {:error, {:failed, :eacces, _message}} = Landlock.probe(stuck)
    end

    test "a missing shim refuses by name" do
      assert Landlock.probe("/nonexistent/fermix_landlock") ==
               {:error, {:shim_missing, "/nonexistent/fermix_landlock"}}

      assert Landlock.describe({:shim_missing, "/x/fermix_landlock"}) ==
               "Commands can't run: Fermix's Landlock shim is missing at /x/fermix_landlock; reinstall Fermix."
    end
  end
end
