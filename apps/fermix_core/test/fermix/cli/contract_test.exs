defmodule Fermix.CLI.ContractTest do
  @moduledoc """
  Guards the typed-CLI export under `priv/cli/` against the code that prints it.

  The `--json` verbs are a **second wire**, read by the Linux desktop client the
  way the management protocol is read by the macOS one, so they get the same
  discipline: a document that says what every field and every code means, one
  golden per published result, and a test that rebuilds every golden from
  `Fermix.CLI.MachineOutput` and the result builders and fails on drift. A
  client vendors this directory; a change here that the client has not
  re-vendored is a drift its own tests refuse, not a silent mismatch.

  Nothing in this file reaches a service manager, a socket or a journal: every
  case is built from an injected identity and injected sources
  (`FermixTestSupport.CliContractCases`).
  """

  use ExUnit.Case, async: true

  alias Fermix.CLI.MachineOutput
  alias Fermix.CLI.Service.Status
  alias FermixCore.Management.Diagnostics.Offline
  alias FermixTestSupport.CliContractCases

  @contract Application.app_dir(:fermix_core, "priv/cli/CONTRACT.md")
  @fixtures Application.app_dir(:fermix_core, "priv/cli/fixtures")

  test "every golden is exactly what the CLI would print today" do
    for {path, expected} <- CliContractCases.cases() do
      file = Path.join(@fixtures, path)

      assert File.exists?(file), """
      the typed-CLI export has no golden for #{path}. Write it:

      #{expected}
      """

      assert File.read!(file) == expected, """
      the #{path} golden no longer matches what the CLI prints. Replace it with:

      #{expected}
      """
    end
  end

  # A directory that carries a file nothing builds is a contract a client can
  # vendor and code against while the daemon never produces it.
  test "no golden exists that no published result builds" do
    published = MapSet.new(CliContractCases.cases(), fn {path, _json} -> path end)

    on_disk =
      @fixtures
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> MapSet.new(&Path.relative_to(&1, @fixtures))

    assert MapSet.to_list(MapSet.difference(on_disk, published)) == []
  end

  test "every published error code has a golden and a documented sentence" do
    document = File.read!(@contract)

    for code <- MachineOutput.codes() do
      name = Atom.to_string(code)
      sentence = MachineOutput.sentence(code, CliContractCases.error_details(code))

      assert File.exists?(Path.join(@fixtures, "errors/#{name}.json")),
             "no golden for the #{name} refusal"

      assert String.contains?(document, "`#{name}`"), "CONTRACT.md does not name #{name}"

      assert String.contains?(document, sentence),
             "CONTRACT.md does not carry the #{name} sentence as it is printed"
    end
  end

  # The client decodes this result field by field, so a key that stopped being
  # documented is a key it will read as absent. A field may be documented bare
  # (`pid`) or qualified (`binding.home`); the leaf name is what has to appear.
  test "CONTRACT.md documents every field of the service status result" do
    documented = documented_names()
    status = CliContractCases.status(:active_aligned)

    for {key, value} <- status do
      assert MapSet.member?(documented, key), "CONTRACT.md does not name #{key}"

      for nested <- nested_keys(value) do
        assert MapSet.member?(documented, nested),
               "CONTRACT.md does not name #{key}.#{nested}"
      end
    end
  end

  defp documented_names do
    ~r/`([A-Za-z0-9_.]+)`/
    |> Regex.scan(File.read!(@contract))
    |> MapSet.new(fn [_match, name] -> name |> String.split(".") |> List.last() end)
  end

  test "CONTRACT.md documents every alignment verdict the comparator can answer" do
    document = File.read!(@contract)

    for state <- CliContractCases.status_states() do
      verdict = CliContractCases.status(state)["alignment"]

      assert String.contains?(document, "`#{verdict}`"),
             "CONTRACT.md does not name the #{verdict} alignment"
    end

    assert String.contains?(document, "`not_running`")
  end

  # The bundle's own version is not the management protocol's, and a reader that
  # assumed otherwise would decode the wrong shape after either one moved.
  test "CONTRACT.md carries the envelope and bundle schema versions in force" do
    document = File.read!(@contract)

    assert String.contains?(document, ~s("schema_version": 1))
    assert Offline.schema_version() == 1
    assert String.contains?(document, "#{Offline.max_bytes()} bytes")
  end

  # The vendor unit path is the one path in the result a client compares
  # against, so the export and the inspector must spell it identically.
  test "CONTRACT.md names the vendor unit path the inspector compares against" do
    assert @contract |> File.read!() |> String.contains?(Status.vendor_unit_path())
  end

  defp nested_keys(value) when is_map(value), do: Map.keys(value)
  defp nested_keys(_value), do: []
end
