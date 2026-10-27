defmodule Mix.Tasks.Fermix.IrohHelperTest do
  # async: false — the Mix shell is global.
  use ExUnit.Case, async: false

  alias FermixTestSupport.SafeRm
  alias Mix.Tasks.Fermix.IrohHelper, as: IrohHelperTask

  @bytes "fake fermix-iroh for macos_aarch64\n"
  @release "https://github.com/tezra-io/fermix-iroh/releases/download/v0.1.0/"
  @url @release <> "fermix-iroh-macos-aarch64"
  @notices "fake third-party notices\n"
  @notices_url @release <> "fermix-iroh-THIRD-PARTY-NOTICES.txt"

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    root = SafeRm.make_tmp_dir!("iroh-helper-task")

    on_exit(fn ->
      Mix.shell(shell)
      SafeRm.rm_rf!(root)
    end)

    priv = Path.join(root, "priv")
    File.mkdir_p!(priv)

    %{priv: priv, pin_path: write_pin!(root)}
  end

  test "installs the host's pinned helper and its notices and says so, then keeps them",
       context do
    fetch = fn
      @url -> {:ok, @bytes}
      @notices_url -> {:ok, @notices}
    end

    path = Path.join(context.priv, "iroh_helper/bin/fermix-iroh")
    notices = Path.join(context.priv, "iroh_helper/THIRD-PARTY-NOTICES.txt")

    assert IrohHelperTask.execute([], host_opts(context, fetch: fetch)) == :ok
    assert File.read!(path) == @bytes
    assert File.read!(notices) == @notices
    assert_received {:mix_shell, :info, [placed]}
    assert placed == "Placed fermix-iroh 0.1.0 for macos_aarch64 at #{path}."
    assert_received {:mix_shell, :info, [placed_notices]}
    assert placed_notices == "Placed its third-party notices at #{notices}."

    kept_opts = host_opts(context, fetch: fn url -> flunk("fetched #{url} again") end)

    assert IrohHelperTask.execute([], kept_opts) == :ok
    assert_received {:mix_shell, :info, [kept]}
    assert kept == "fermix-iroh 0.1.0 for macos_aarch64 is already at #{path}; kept it."
    assert_received {:mix_shell, :info, [kept_notices]}
    assert kept_notices == "Its third-party notices are already at #{notices}; kept them."
  end

  test "refuses a host no helper is built for, before fetching anything", context do
    opts =
      host_opts(context,
        os_type: {:unix, :freebsd},
        system_architecture: ~c"x86_64-unknown-freebsd14.1",
        fetch: fn url -> flunk("fetched #{url} for an unsupported host") end
      )

    error = assert_raise Mix.Error, fn -> IrohHelperTask.execute([], opts) end

    assert error.message ==
             "fermix-iroh is built for macOS and Linux on aarch64 and x86_64, and this host " <>
               "is {:unix, :freebsd} x86_64-unknown-freebsd14.1"

    refute File.exists?(Path.join(context.priv, "iroh_helper"))
  end

  test "takes no arguments", context do
    assert_raise Mix.Error, "usage: mix fermix.iroh_helper", fn ->
      IrohHelperTask.execute(["--force"], host_opts(context, []))
    end
  end

  test "names the host's target from the OS and the system architecture" do
    cases = [
      {{:unix, :darwin}, ~c"aarch64-apple-darwin25.0.0", {:ok, "macos_aarch64"}},
      {{:unix, :darwin}, ~c"x86_64-apple-darwin24.6.0", {:ok, "macos_x86_64"}},
      {{:unix, :linux}, ~c"aarch64-unknown-linux-gnu", {:ok, "linux_aarch64"}},
      {{:unix, :linux}, ~c"x86_64-pc-linux-musl", {:ok, "linux_x86_64"}},
      {{:unix, :linux}, ~c"riscv64-unknown-linux-gnu", :unsupported},
      {{:win32, :nt}, ~c"win32", :unsupported}
    ]

    for {os_type, architecture, expected} <- cases do
      assert IrohHelperTask.host_target(os_type, architecture) == expected,
             "#{inspect(os_type)} #{architecture}"
    end
  end

  test "installs into the source tree's fermix_core priv by default" do
    assert IrohHelperTask.default_priv_dir() == FermixCore.Release.IrohHelper.source_priv_dir()
    assert File.regular?(Path.join(IrohHelperTask.default_priv_dir(), "iroh_helper/PIN.json"))
  end

  defp host_opts(context, overrides) do
    Keyword.merge(
      [
        priv_dir: context.priv,
        pin_path: context.pin_path,
        os_type: {:unix, :darwin},
        system_architecture: ~c"aarch64-apple-darwin25.0.0"
      ],
      overrides
    )
  end

  defp write_pin!(root) do
    targets =
      Map.new(~w(macos_aarch64 macos_x86_64 linux_aarch64 linux_x86_64), fn target ->
        asset = "fermix-iroh-" <> String.replace(target, "_", "-", global: false)
        bytes = "fake fermix-iroh for #{target}\n"
        {target, %{"asset" => asset, "sha256" => sha256(bytes)}}
      end)

    path = Path.join(root, "PIN.json")

    File.write!(
      path,
      Jason.encode!(%{
        "schema_version" => 2,
        "repository" => "tezra-io/fermix-iroh",
        "tag" => "v0.1.0",
        "version" => "0.1.0",
        "protocol_version" => 1,
        "iroh_version" => "1.3.0",
        "notices" => %{
          "asset" => "fermix-iroh-THIRD-PARTY-NOTICES.txt",
          "sha256" => sha256(@notices)
        },
        "targets" => targets
      })
    )

    path
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
