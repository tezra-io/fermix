defmodule Fermix.CLI.PackagedDocumentationTest do
  @moduledoc """
  What the Linux package installs is checked into `packaging/linux/` (M38 §2.2)
  and what the engine expects is in this repository, so nothing but a test
  keeps the two in step.

  The man page and the three shell completions describe a command set: a verb
  added to `Fermix.CLI` and not to those files ships a package that documents
  a binary that no longer exists. The verb list is read from the dispatcher
  itself rather than written twice — `defp dispatch("verb", …)` is the whole
  surface, plus the two flag lists that carry `help` and `version`.

  Two installed paths are load-bearing the same way: the vendor unit's, which
  `service status` compares the effective unit against, and the packaged helper
  directory the shared `PATH` baseline appends so the bundled `cosign` is
  reachable at all.
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.Service.Status
  alias FermixCore.Boot.PathBaseline

  @packaging Path.expand("../../../../../packaging/linux", __DIR__)
  @cli_source Path.expand("../../../lib/fermix/cli.ex", __DIR__)

  setup_all do
    source = File.read!(@cli_source)

    dispatched =
      ~r/defp dispatch\("([a-z-]+)"/
      |> Regex.scan(source, capture: :all_but_first)
      |> List.flatten()

    %{verbs: MapSet.new(dispatched ++ flag_verbs(source))}
  end

  test "the man page documents every verb the dispatcher answers", %{verbs: verbs} do
    page = File.read!(Path.join(@packaging, "man/fermix.1"))

    documented =
      MapSet.new(Regex.scan(~r/^\.B fermix ([a-z-]+)$/m, page, capture: :all_but_first), &hd/1)

    assert MapSet.to_list(MapSet.difference(verbs, documented)) == []
    assert MapSet.to_list(MapSet.difference(documented, verbs)) == []
  end

  test "the man page names no version and no release date of its own" do
    page = File.read!(Path.join(@packaging, "man/fermix.1"))

    refute page =~ ~r/\d+\.\d+\.\d+/
  end

  for {shell, file, pattern} <- [
        {"bash", "completions/fermix.bash", ~r/local verbs="([^"]+)"/},
        {"zsh", "completions/_fermix", ~r/_fermix_verbs=\(([^)]+)\)/},
        {"fish", "completions/fermix.fish", ~r/set -l fermix_verbs (.+)/}
      ] do
    test "the #{shell} completion offers exactly the verbs the dispatcher answers", %{
      verbs: verbs
    } do
      contents = File.read!(Path.join(@packaging, unquote(file)))
      [[listed]] = Regex.scan(unquote(Macro.escape(pattern)), contents, capture: :all_but_first)
      offered = listed |> String.split() |> MapSet.new()

      assert MapSet.to_list(MapSet.difference(verbs, offered)) == []
      assert MapSet.to_list(MapSet.difference(offered, verbs)) == []
    end
  end

  test "the fish completion offers a per-verb entry for every verb", %{verbs: verbs} do
    contents = File.read!(Path.join(@packaging, "completions/fermix.fish"))

    completed =
      MapSet.new(
        Regex.scan(~r/-a ([a-z-]+) -d /, contents, capture: :all_but_first),
        &hd/1
      )

    assert MapSet.to_list(MapSet.difference(verbs, completed)) == []
  end

  test "the package installs the vendor unit where the status inspector looks" do
    assert template() =~ "dst: #{Status.vendor_unit_path()}"
  end

  test "the bundled verifier lands in the directory the PATH baseline appends" do
    helper_dir = List.last(PathBaseline.dirs(os: :linux))

    assert helper_dir == "/usr/lib/fermix"
    assert template() =~ "dst: #{helper_dir}/cosign"
  end

  test "the package carries no Debian revision and no epoch" do
    assert template() =~ ~s(release: "")
    refute template() =~ "epoch:"
  end

  defp template, do: File.read!(Path.join(@packaging, "nfpm-fermix.yaml.tmpl"))

  defp flag_verbs(source) do
    ~r/@(?:help|version)_flags ~w\(([^)]+)\)/
    |> Regex.scan(source, capture: :all_but_first)
    |> Enum.flat_map(fn [list] -> String.split(list) end)
    |> Enum.reject(&String.starts_with?(&1, "-"))
  end
end
