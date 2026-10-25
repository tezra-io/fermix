defmodule FermixCore.Release.IrohHelperTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias FermixCore.Release.IrohHelper
  alias FermixTestSupport.SafeRm

  @targets ~w(macos_aarch64 macos_x86_64 linux_aarch64 linux_x86_64)
  @release "https://github.com/tezra-io/fermix-iroh/releases/download/v0.1.0/"
  @url @release <> "fermix-iroh-linux-x86_64"
  @notices_url @release <> "fermix-iroh-THIRD-PARTY-NOTICES.txt"
  @notices "MIT License\n\nCopyright (c) 2026 Tezra.io\n\nthird-party notices for every target\n"

  setup do
    root = SafeRm.make_tmp_dir!("iroh-helper")
    on_exit(fn -> SafeRm.rm_rf!(root) end)

    priv = Path.join(root, "priv")
    File.mkdir_p!(priv)

    %{root: root, priv: priv, pin_path: write_pin!(root)}
  end

  describe "place/3" do
    test "fetches each pinned asset once and places the helper and its notices", context do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      assert %{action: :placed, path: path, notices: notices, version: "0.1.0"} =
               IrohHelper.place(:linux_x86_64, context.priv,
                 pin_path: context.pin_path,
                 fetch: serve(calls, linux_assets())
               )

      assert path == Path.join(context.priv, "iroh_helper/bin/fermix-iroh")
      assert File.read!(path) == helper_bytes("linux_x86_64")
      assert mode(path) == 0o755
      assert notices == %{action: :placed, path: notices_path(context.priv)}
      assert File.read!(notices.path) == @notices
      assert mode(notices.path) == 0o644
      assert Agent.get(calls, & &1) == [@url, @notices_url]
      assert bin_entries(context.priv) == ["fermix-iroh"]

      assert Enum.sort(File.ls!(Path.join(context.priv, "iroh_helper"))) ==
               ["THIRD-PARTY-NOTICES.txt", "bin"]
    end

    test "takes the target as the string the compiled identity carries", context do
      url =
        "https://github.com/tezra-io/fermix-iroh/releases/download/v0.1.0/" <>
          "fermix-iroh-macos-aarch64"

      assets = %{url => helper_bytes("macos_aarch64"), @notices_url => @notices}
      {:ok, calls} = Agent.start_link(fn -> [] end)

      assert %{action: :placed, path: path} =
               IrohHelper.place("macos_aarch64", context.priv,
                 pin_path: context.pin_path,
                 fetch: serve(calls, assets)
               )

      assert File.read!(path) == helper_bytes("macos_aarch64")
      assert File.read!(notices_path(context.priv)) == @notices
    end

    test "keeps destinations that already have the pinned digests, fetching nothing", context do
      path = destination(context.priv)
      put_file!(path, helper_bytes("linux_x86_64"), 0o644)
      put_file!(notices_path(context.priv), @notices, 0o600)

      assert %{action: :kept, path: ^path, notices: %{action: :kept}} =
               IrohHelper.place(:linux_x86_64, context.priv,
                 pin_path: context.pin_path,
                 fetch: fn url -> flunk("fetched #{url} for a file already in place") end
               )

      assert mode(path) == 0o755
      assert mode(notices_path(context.priv)) == 0o644
    end

    test "leaves kept files that already have their modes untouched", context do
      paths = [destination(context.priv), notices_path(context.priv)]
      put_file!(destination(context.priv), helper_bytes("linux_x86_64"), 0o755)
      put_file!(notices_path(context.priv), @notices, 0o644)
      for path <- paths, do: File.touch!(path, {{2026, 1, 2}, {3, 4, 5}})
      before = Enum.map(paths, &mtime/1)

      assert %{action: :kept, notices: %{action: :kept}} =
               IrohHelper.place(:linux_x86_64, context.priv,
                 pin_path: context.pin_path,
                 fetch: fn url -> flunk("fetched #{url} for a file already in place") end
               )

      assert Enum.map(paths, &mtime/1) == before
    end

    test "keeps a placed helper and fetches only the notices it lacks", context do
      path = destination(context.priv)
      put_file!(path, helper_bytes("linux_x86_64"), 0o755)
      {:ok, calls} = Agent.start_link(fn -> [] end)

      assert %{action: :kept, path: ^path, notices: %{action: :placed}} =
               IrohHelper.place(:linux_x86_64, context.priv,
                 pin_path: context.pin_path,
                 fetch: serve(calls, %{@notices_url => @notices})
               )

      assert Agent.get(calls, & &1) == [@notices_url]
      assert File.read!(notices_path(context.priv)) == @notices
    end

    test "replaces a destination whose digest is not the pin's", context do
      path = destination(context.priv)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "a helper from another release")
      {:ok, calls} = Agent.start_link(fn -> [] end)

      assert %{action: :placed, path: ^path} =
               IrohHelper.place(:linux_x86_64, context.priv,
                 pin_path: context.pin_path,
                 fetch: serve(calls, linux_assets())
               )

      assert File.read!(path) == helper_bytes("linux_x86_64")
    end

    test "refuses fetched bytes whose digest is not the pin's and leaves nothing", context do
      error =
        assert_raise RuntimeError, fn ->
          IrohHelper.place(:linux_x86_64, context.priv,
            pin_path: context.pin_path,
            fetch: fn @url -> {:ok, "not the pinned helper"} end
          )
        end

      expected = digest(helper_bytes("linux_x86_64"))
      actual = digest("not the pinned helper")

      assert error.message ==
               "the fermix-iroh helper fetched for linux_x86_64 has digest #{actual}, " <>
                 "and the pin names #{expected}"

      assert bin_entries(context.priv) == []
    end

    test "a refused fetch leaves an old destination untouched and no temporary file", context do
      path = destination(context.priv)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "a helper from another release")

      assert_raise RuntimeError, ~r/has digest/, fn ->
        IrohHelper.place(:linux_x86_64, context.priv,
          pin_path: context.pin_path,
          fetch: fn @url -> {:ok, "not the pinned helper"} end
        )
      end

      assert File.read!(path) == "a helper from another release"
      assert bin_entries(context.priv) == ["fermix-iroh"]
    end

    test "refuses fetched notices whose digest is not the pin's and leaves no notices", context do
      error =
        assert_raise RuntimeError, fn ->
          IrohHelper.place(:linux_x86_64, context.priv,
            pin_path: context.pin_path,
            fetch: fn
              @url -> {:ok, helper_bytes("linux_x86_64")}
              @notices_url -> {:ok, "not the pinned notices"}
            end
          )
        end

      assert error.message ==
               "the fermix-iroh notices file fetched for linux_x86_64 has digest " <>
                 "#{digest("not the pinned notices")}, and the pin names #{digest(@notices)}"

      assert File.ls!(Path.join(context.priv, "iroh_helper")) == ["bin"]
    end

    test "a notices transport failure names the target, the URL and the HTTP status", context do
      error =
        assert_raise RuntimeError, fn ->
          IrohHelper.place(:linux_x86_64, context.priv,
            pin_path: context.pin_path,
            fetch: fn
              @url -> {:ok, helper_bytes("linux_x86_64")}
              @notices_url -> {:error, {:http_status, 404}}
            end
          )
        end

      assert error.message ==
               "cannot fetch the fermix-iroh notices file for linux_x86_64 from " <>
                 "#{@notices_url}: HTTP 404"

      refute File.exists?(notices_path(context.priv))
    end

    test "a transport failure names the target, the URL and the HTTP status", context do
      error =
        assert_raise RuntimeError, fn ->
          IrohHelper.place(:linux_x86_64, context.priv,
            pin_path: context.pin_path,
            fetch: fn @url -> {:error, {:http_status, 404}} end
          )
        end

      assert error.message ==
               "cannot fetch the fermix-iroh helper for linux_x86_64 from #{@url}: HTTP 404"

      assert bin_entries(context.priv) == []
    end

    test "a transport failure names Req's reason", context do
      error =
        assert_raise RuntimeError, fn ->
          IrohHelper.place(:linux_x86_64, context.priv,
            pin_path: context.pin_path,
            fetch: fn @url -> {:error, %Req.TransportError{reason: :nxdomain}} end
          )
        end

      assert error.message ==
               "cannot fetch the fermix-iroh helper for linux_x86_64 from #{@url}: " <>
                 "non-existing domain"
    end

    test "an unknown target names the four the pin knows", context do
      error =
        assert_raise RuntimeError, fn ->
          IrohHelper.place(:windows_x86_64, context.priv,
            pin_path: context.pin_path,
            fetch: fn url -> flunk("fetched #{url} for an unknown target") end
          )
        end

      assert error.message ==
               "fermix-iroh has no pinned build for target windows_x86_64; the pin names " <>
                 "linux_aarch64, linux_x86_64, macos_aarch64 and macos_x86_64"

      refute File.exists?(Path.join(context.priv, "iroh_helper"))
    end

    test "refuses a pin that does not name exactly the four targets", context do
      {_dropped, pin} =
        context.pin_path |> File.read!() |> Jason.decode!() |> pop_in(["targets", "linux_x86_64"])

      File.write!(context.pin_path, Jason.encode!(pin))

      assert_raise RuntimeError, ~r/is not a valid fermix-iroh pin: targets/, fn ->
        IrohHelper.place(:macos_aarch64, context.priv, pin_path: context.pin_path)
      end
    end

    test "refuses a pin that names no notices, or notices it cannot place", context do
      pin = context.pin_path |> File.read!() |> Jason.decode!()

      assert pin_problem(context, Map.delete(pin, "notices")) ==
               "notices needs an asset and a sha256"

      assert pin_problem(context, put_in(pin, ["notices", "sha256"], "ABC")) ==
               "notices.sha256 is not a lowercase sha256 digest"

      assert pin_problem(context, put_in(pin, ["notices", "asset"], "../notices")) ==
               "notices.asset is invalid"

      refute File.exists?(Path.join(context.priv, "iroh_helper"))
    end

    # A schema 1 pin predates the notices, so placing from it would ship a
    # helper without them.
    test "refuses a schema 1 pin", context do
      pin = context.pin_path |> File.read!() |> Jason.decode!()
      File.write!(context.pin_path, Jason.encode!(%{pin | "schema_version" => 1}))

      assert_raise RuntimeError, ~r/pin: schema_version is not 2/, fn ->
        IrohHelper.place(:linux_x86_64, context.priv, pin_path: context.pin_path)
      end
    end
  end

  describe "fetch/2" do
    test "returns the body exactly as served, without decoding it" do
      gzip = :zlib.gzip("helper bytes")

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-encoding", "gzip")
        |> Plug.Conn.send_resp(200, gzip)
      end

      assert IrohHelper.fetch(@url, plug: plug) == {:ok, gzip}
    end

    test "answers a status that is not 200 as that status, without retrying" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      plug = fn conn ->
        Agent.update(calls, &(&1 + 1))
        Plug.Conn.send_resp(conn, 503, "unavailable")
      end

      assert IrohHelper.fetch(@url, plug: plug) == {:error, {:http_status, 503}}
      assert Agent.get(calls, & &1) == 1
    end

    test "answers a transport failure as Req's exception" do
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               IrohHelper.fetch(@url, plug: plug)
    end
  end

  describe "the Burrito step" do
    test "places the target's helper in the one fermix_core priv and returns the context",
         context do
      work_dir = fake_work_dir!(context.root, ["fermix_core-0.15.0", "fermix_nif-0.1.0"])
      burrito = fake_context(work_dir, :linux_x86_64)
      {:ok, calls} = Agent.start_link(fn -> [] end)

      log =
        capture_io(fn ->
          assert IrohHelper.run(burrito,
                   pin_path: context.pin_path,
                   fetch: serve(calls, linux_assets())
                 ) == burrito
        end)

      priv = Path.join(work_dir, "lib/fermix_core-0.15.0/priv")
      path = destination(priv)
      assert File.read!(path) == helper_bytes("linux_x86_64")
      assert File.read!(notices_path(priv)) == @notices
      assert log =~ "fermix: fermix-iroh 0.1.0 for linux_x86_64 placed at #{path}"
      assert log =~ "fermix: its third-party notices placed at #{notices_path(priv)}"
      refute File.exists?(Path.join(work_dir, "lib/fermix_nif-0.1.0/priv/iroh_helper"))
    end

    test "refuses a work_dir with no fermix_core priv", context do
      work_dir = fake_work_dir!(context.root, ["fermix_nif-0.1.0"])

      assert_raise RuntimeError, ~r/exactly one fermix_core priv directory.*found none/, fn ->
        IrohHelper.run(fake_context(work_dir, :linux_x86_64), pin_path: context.pin_path)
      end
    end

    test "refuses a work_dir with two fermix_core trees", context do
      work_dir = fake_work_dir!(context.root, ["fermix_core-0.14.0", "fermix_core-0.15.0"])

      assert_raise RuntimeError, ~r/exactly one fermix_core priv directory.*found 2/, fn ->
        IrohHelper.run(fake_context(work_dir, :linux_x86_64), pin_path: context.pin_path)
      end
    end
  end

  describe "the app-engine release step" do
    test "places the compiled target's helper in the assembled fermix_core priv", context do
      release = fake_release!(context.root)

      url =
        "https://github.com/tezra-io/fermix-iroh/releases/download/v0.1.0/" <>
          "fermix-iroh-macos-aarch64"

      assets = %{url => helper_bytes("macos_aarch64"), @notices_url => @notices}
      {:ok, calls} = Agent.start_link(fn -> [] end)

      log =
        capture_io(fn ->
          assert IrohHelper.place_in_release(release,
                   target: "macos_aarch64",
                   pin_path: context.pin_path,
                   fetch: serve(calls, assets)
                 ) == release
        end)

      priv = Path.join(release.path, "lib/fermix_core-0.15.0/priv")
      path = destination(priv)
      assert File.read!(path) == helper_bytes("macos_aarch64")
      assert mode(path) == 0o755
      assert File.read!(notices_path(priv)) == @notices
      assert mode(notices_path(priv)) == 0o644
      assert log =~ "fermix: fermix-iroh 0.1.0 for macos_aarch64 placed at #{path}"
      assert log =~ "fermix: its third-party notices placed at #{notices_path(priv)}"
    end

    test "refuses a release whose fermix_core tree has no priv", context do
      release = fake_release!(context.root)
      SafeRm.rm_rf!(Path.join(release.path, "lib/fermix_core-0.15.0/priv"))

      assert_raise RuntimeError, ~r/has no .*fermix_core-0\.15\.0\/priv/, fn ->
        IrohHelper.place_in_release(release, target: "macos_aarch64", pin_path: context.pin_path)
      end
    end
  end

  describe "the checked-in pin" do
    test "names the four targets with a digest each" do
      pin = IrohHelper.read_pin!()

      assert pin["repository"] == "tezra-io/fermix-iroh"
      assert pin["tag"] == "v" <> pin["version"]
      assert pin["targets"] |> Map.keys() |> Enum.sort() == Enum.sort(@targets)

      for {_target, %{"sha256" => sha256}} <- pin["targets"],
          do: assert(sha256 =~ ~r/\A[0-9a-f]{64}\z/)

      assert pin["notices"]["asset"] == "fermix-iroh-THIRD-PARTY-NOTICES.txt"
      assert pin["notices"]["sha256"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "sits beside the protocol the helper speaks, in the source priv" do
      assert IrohHelper.pin_path() ==
               Path.join(IrohHelper.source_priv_dir(), "iroh_helper/PIN.json")

      assert File.regular?(Path.join(IrohHelper.source_priv_dir(), "iroh_helper/PROTOCOL.md"))
    end
  end

  defp helper_bytes(target), do: "fake fermix-iroh for #{target}\n"

  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp write_pin!(root) do
    targets =
      Map.new(@targets, fn target ->
        asset = "fermix-iroh-" <> String.replace(target, "_", "-", global: false)
        {target, %{"asset" => asset, "sha256" => digest(helper_bytes(target))}}
      end)

    pin = %{
      "schema_version" => 2,
      "repository" => "tezra-io/fermix-iroh",
      "tag" => "v0.1.0",
      "version" => "0.1.0",
      "protocol_version" => 1,
      "iroh_version" => "1.3.0",
      "notices" => %{
        "asset" => "fermix-iroh-THIRD-PARTY-NOTICES.txt",
        "sha256" => digest(@notices)
      },
      "targets" => targets
    }

    path = Path.join(root, "PIN.json")
    File.write!(path, Jason.encode!(pin))
    path
  end

  defp serve(calls, bodies) do
    fn url ->
      Agent.update(calls, &(&1 ++ [url]))
      Map.fetch!(bodies, url) |> then(&{:ok, &1})
    end
  end

  defp linux_assets, do: %{@url => helper_bytes("linux_x86_64"), @notices_url => @notices}

  defp destination(priv), do: Path.join(priv, "iroh_helper/bin/fermix-iroh")

  defp notices_path(priv), do: Path.join(priv, "iroh_helper/THIRD-PARTY-NOTICES.txt")

  defp put_file!(path, bytes, mode) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    File.chmod!(path, mode)
  end

  defp mtime(path), do: File.stat!(path, time: :posix).mtime

  # The problem `place/3` names for `pin`, written over the context's pin.
  defp pin_problem(context, pin) do
    File.write!(context.pin_path, Jason.encode!(pin))

    error =
      assert_raise RuntimeError, fn ->
        IrohHelper.place(:linux_x86_64, context.priv,
          pin_path: context.pin_path,
          fetch: fn url -> flunk("fetched #{url} with an invalid pin") end
        )
      end

    prefix = "#{context.pin_path} is not a valid fermix-iroh pin: "
    String.replace_prefix(error.message, prefix, "")
  end

  defp bin_entries(priv) do
    case File.ls(Path.join(priv, "iroh_helper/bin")) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, :enoent} -> []
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  defp fake_work_dir!(root, apps) do
    work_dir = Path.join(root, "work")
    for app <- apps, do: File.mkdir_p!(Path.join([work_dir, "lib", app, "priv"]))
    work_dir
  end

  defp fake_context(work_dir, target) do
    %{
      target: %{alias: target, os: :linux, cpu: :x86_64},
      work_dir: work_dir,
      self_dir: "/nonexistent/burrito",
      extra_build_env: [],
      halted: false
    }
  end

  defp fake_release!(root) do
    path = Path.join(root, "rel/fermix_app_engine")
    File.mkdir_p!(Path.join(path, "lib/fermix_core-0.15.0/priv"))

    %{
      name: :fermix_app_engine,
      path: path,
      applications: %{
        fermix_core: [vsn: ~c"0.15.0", path: ~c"/build/lib/fermix_core"],
        fermix_nif: [vsn: ~c"0.1.0", path: ~c"/build/lib/fermix_nif"]
      }
    }
  end
end
