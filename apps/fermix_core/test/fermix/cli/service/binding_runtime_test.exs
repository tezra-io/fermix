defmodule Fermix.CLI.Service.BindingRuntimeTest do
  @moduledoc """
  The binding read `config/runtime.exs` performs for `fermix service run`.

  That file is the boot config-provider chain and cannot be unit tested, so what
  is pinned here is the exact call it makes — `Binding.read/1` with no options,
  resolved through `XDG_CONFIG_HOME` — and the three outcomes it branches on.

  `XDG_CONFIG_HOME` is process-global, so this module establishes it in its own
  `setup`, restores it in `on_exit`, and is `async: false`.
  """

  use ExUnit.Case, async: false

  alias Fermix.CLI.Service.Binding
  alias FermixTestSupport.SafeRm

  setup do
    original = System.get_env("XDG_CONFIG_HOME")
    root = SafeRm.make_tmp_dir!("binding_runtime_root")
    System.put_env("XDG_CONFIG_HOME", root)

    on_exit(fn ->
      case original do
        nil -> System.delete_env("XDG_CONFIG_HOME")
        value -> System.put_env("XDG_CONFIG_HOME", value)
      end

      SafeRm.rm_rf!(root)
    end)

    %{root: root}
  end

  test "the home the service was installed with is what the unit's boot reads" do
    assert Binding.write("/home/operator/.fermix", []) == :ok

    assert Binding.read([]) == {:ok, %{home: "/home/operator/.fermix"}}
  end

  # The three outcomes the vendor unit's boot branches on: put FERMIX_HOME,
  # refuse with the install command, refuse with the binding's own sentence.
  # None of them is "guess the default home".
  test "an unbound account is missing, and a broken binding carries its sentence", %{root: root} do
    assert Binding.read([]) == {:error, :missing}

    path = Binding.path([])
    assert path == Path.join([root, "fermix", "service.json"])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "home" => "relative"}))

    assert {:error, {:invalid, sentence}} = Binding.read([])
    assert sentence =~ "absolute"
  end
end
