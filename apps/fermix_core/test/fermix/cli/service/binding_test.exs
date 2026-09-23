defmodule Fermix.CLI.Service.BindingTest do
  @moduledoc """
  The CLI-owned service binding (M38 §4.7).

  Every case injects `:root`, so nothing here reads or writes the operator's
  real `~/.config`.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Service.Binding
  alias FermixCore.SocketPath
  alias FermixTestSupport.SafeRm

  setup do
    root = SafeRm.make_tmp_dir!("service_binding_root")
    on_exit(fn -> SafeRm.rm_rf!(root) end)
    %{root: root}
  end

  describe "path/1" do
    test "lives under the injected root", %{root: root} do
      assert Binding.path(root: root) == Path.join([root, "fermix", "service.json"])
    end

    test "defaults to the XDG config root", %{root: root} do
      assert Binding.path(config_home: root) == Path.join([root, "fermix", "service.json"])
    end

    test "falls back to ~/.config when XDG_CONFIG_HOME is unset or blank" do
      expected = Path.join([System.user_home!(), ".config", "fermix", "service.json"])

      assert Binding.path(config_home: nil) == expected
      assert Binding.path(config_home: "") == expected
    end
  end

  describe "read/1" do
    test "an absent file is missing, not invalid", %{root: root} do
      assert Binding.read(root: root) == {:error, :missing}
    end

    test "a written binding round-trips", %{root: root} do
      home = "/home/operator/my fermix/100% home"

      assert Binding.write(home, root: root) == :ok
      assert Binding.read(root: root) == {:ok, %{home: home}}
    end

    test "unparsable content is invalid and names the file", %{root: root} do
      path = Binding.path(root: root)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "{not json")

      assert {:error, {:invalid, sentence}} = Binding.read(root: root)
      assert sentence =~ path
      assert sentence =~ "could not be read"
    end

    test "an unknown schema version is invalid", %{root: root} do
      path = Binding.path(root: root)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"schema_version" => 2, "home" => "/home/o/.fermix"}))

      assert {:error, {:invalid, sentence}} = Binding.read(root: root)
      assert sentence =~ "schema version"
    end

    test "a home that fails validation is invalid, never a guessed default", %{root: root} do
      path = Binding.path(root: root)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"schema_version" => 1, "home" => "relative/home"}))

      assert {:error, {:invalid, sentence}} = Binding.read(root: root)
      assert sentence =~ "absolute"
    end

    test "a missing home key is invalid", %{root: root} do
      path = Binding.path(root: root)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(%{"schema_version" => 1}))

      assert {:error, {:invalid, _sentence}} = Binding.read(root: root)
    end
  end

  describe "write/2" do
    test "the directory is 0700 and the file 0600", %{root: root} do
      assert Binding.write("/home/o/.fermix", root: root) == :ok

      path = Binding.path(root: root)
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
    end

    test "the payload carries the schema version and nothing else", %{root: root} do
      assert Binding.write("/home/o/.fermix", root: root) == :ok

      assert Jason.decode!(File.read!(Binding.path(root: root))) == %{
               "schema_version" => 1,
               "home" => "/home/o/.fermix"
             }
    end

    test "a rewrite replaces the previous home and leaves no temporary file", %{root: root} do
      assert Binding.write("/home/o/.fermix", root: root) == :ok
      assert Binding.write("/home/o/other", root: root) == :ok

      assert Binding.read(root: root) == {:ok, %{home: "/home/o/other"}}
      assert File.ls!(Path.dirname(Binding.path(root: root))) == ["service.json"]
    end

    test "an invalid home is refused before anything is written", %{root: root} do
      assert {:error, {:invalid, sentence}} = Binding.write("relative", root: root)
      assert sentence =~ "absolute"
      refute File.exists?(Path.dirname(Binding.path(root: root)))
    end
  end

  describe "validate/1" do
    test "accepts an absolute home carrying spaces and percent characters" do
      assert Binding.validate("/home/operator/My Files/100%") == :ok
    end

    test "refuses a relative home" do
      assert {:error, {:invalid, sentence}} = Binding.validate("home/o/.fermix")
      assert sentence =~ "absolute"
    end

    test "refuses an empty home" do
      assert {:error, {:invalid, _sentence}} = Binding.validate("")
    end

    test "refuses control characters" do
      assert {:error, {:invalid, sentence}} = Binding.validate("/home/o/.fer\nmix")
      assert sentence =~ "control character"

      assert {:error, {:invalid, _null}} = Binding.validate("/home/o/.fer\0mix")
    end

    # The binding names a home whose `daemon.sock` has to fit `sun_path`, so the
    # refusal happens when the home is chosen rather than at the daemon's bind.
    test "refuses a home whose daemon socket would not fit the OS address" do
      limit = SocketPath.max_bytes()
      home = "/" <> String.duplicate("h", limit)

      assert {:error, {:invalid, sentence}} = Binding.validate(home)
      assert sentence =~ "daemon.sock"
      assert sentence =~ "#{limit}-byte limit"
      assert sentence =~ "Choose a shorter home"
    end

    test "accepts the longest home whose daemon socket still fits" do
      limit = SocketPath.max_bytes()
      home = "/" <> String.duplicate("h", limit - byte_size("/daemon.sock") - 1)

      assert byte_size(Path.join(home, "daemon.sock")) == limit
      assert Binding.validate(home) == :ok
    end

    test "refuses anything that is not a string" do
      assert {:error, {:invalid, _sentence}} = Binding.validate(nil)
    end
  end
end
