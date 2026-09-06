defmodule FermixCore.Management.Doctor.RemediationTest do
  @moduledoc """
  The remediation descriptors from M34 native setup §7.3.

  The invariant is written over the whole table rather than over a list of
  interesting entries, so an entry added later either satisfies it or fails the
  test — a hand-maintained case list is the failure this style exists to avoid.
  """

  use ExUnit.Case, async: true

  alias FermixCore.Management.Doctor.Descriptor
  alias FermixCore.Management.Doctor.Remediation

  test "a check with no entry publishes no remediation rather than an empty one" do
    assert Remediation.fetch("readiness", "passed") == nil
    assert Remediation.fetch("no_such_check", "failed") == nil
  end

  test "an entry carries a title, a body and one action" do
    assert %{"title" => title, "body" => body, "action" => action} =
             Remediation.fetch("legacy_service_unit", "warning")

    assert is_binary(title) and title != ""
    assert is_binary(body) and body != ""
    assert action["kind"] == "instructions"
    assert action["target"] == "legacy_service_unit.removal"
  end

  # Every entry, not a chosen few: the population most likely to change is the
  # one an entry-by-entry test would miss.
  test "every published entry is well formed" do
    for key <- Remediation.keys() do
      [id, status] = String.split(key, ".", parts: 2)
      entry = Remediation.fetch(id, status)

      assert entry, "no entry for #{key}"
      assert byte_size(entry["title"]) <= 256
      assert byte_size(entry["body"]) <= 256
      assert entry["action"]["kind"] in Remediation.action_kinds()
      assert is_binary(entry["action"]["target"]) or is_nil(entry["action"]["target"])
      assert status in Descriptor.statuses(), "#{key} names a status no check can finish in"
    end
  end

  # Wire copy: sentence case, no em dashes, no exclamation marks, no version
  # numbers. The daemon owns these words and both doors render them verbatim.
  test "every published sentence follows the wire copy rules" do
    for key <- Remediation.keys(), field <- ["title", "body"] do
      [id, status] = String.split(key, ".", parts: 2)
      sentence = Remediation.fetch(id, status)[field]

      refute sentence =~ "—", "#{key} #{field} carries an em dash"
      refute sentence =~ "!", "#{key} #{field} carries an exclamation mark"
      refute sentence =~ ~r/\d+\.\d+\.\d+/, "#{key} #{field} carries a version number"
    end
  end

  # A restart is `lifecycle.prepare` then `lifecycle.commit` and a reload is a
  # request, so neither target names a job. Publishing them as `job` forced every
  # client to special-case two targets under a kind documented as "start the
  # named job"; the kind names the operation instead and carries no second
  # identifier.
  test "restart and reload are their own kinds rather than jobs" do
    assert Remediation.fetch("restart_pending", "warning")["action"] ==
             %{"kind" => "restart", "target" => nil}

    assert Remediation.fetch("external_config_change", "warning")["action"] ==
             %{"kind" => "reload", "target" => nil}
  end

  # The vocabulary the daemon publishes and the schema the app vendors are one
  # list. A kind the table mints and the contract does not name is an action
  # nothing on the other side can render.
  test "the schema's remediation kinds are the ones the table publishes" do
    schema =
      :fermix_core
      |> Application.app_dir("priv/management/protocol.schema.json")
      |> File.read!()
      |> Jason.decode!()

    assert schema["$defs"]["remediationAction"]["properties"]["kind"]["enum"] ==
             Remediation.action_kinds()
  end

  test "a none action still names a kind so a surface never guesses" do
    assert %{"action" => %{"kind" => "none", "target" => nil}} =
             Remediation.fetch("engine_path_baseline", "warning")
  end

  describe "on a rendered descriptor" do
    test "a passing check carries a null remediation beside its null code" do
      result = Descriptor.run(spec("readiness", fn -> pass() end))

      assert result["remediation_code"] == nil
      assert result["remediation"] == nil
    end

    test "a failing check carries the remediation keyed by its own code" do
      result = Descriptor.run(spec("legacy_service_unit", fn -> warn() end))

      assert result["remediation_code"] == "legacy_service_unit.warning"
      assert result["remediation"]["action"]["kind"] == "instructions"
    end

    test "a cancelled check carries no remediation" do
      result = Descriptor.pending(spec("legacy_service_unit", fn -> warn() end), :cancelled)

      assert result["remediation"] == nil
    end
  end

  defp spec(id, run) do
    %{
      id: id,
      category: :runtime,
      severity: :warning,
      applicability: :always,
      origin: :engine,
      run: run
    }
  end

  defp pass, do: %{name: "readiness", status: :ok, detail: "ready"}
  defp warn, do: %{name: "legacy_service_unit", status: :warn, detail: "another unit"}
end
