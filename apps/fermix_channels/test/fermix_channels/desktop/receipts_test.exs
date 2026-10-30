defmodule FermixChannels.Desktop.ReceiptsTest do
  @moduledoc """
  M75 §11: a desktop's receipts, `<home>/device/receipts.jsonl`. One line per
  decided invocation with hashes only, the newest 1,000 kept and looked up, a
  line torn by a crash skipped, and the file private.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias FermixChannels.Desktop.Receipts
  alias FermixTestSupport.SafeRm

  setup do
    home = SafeRm.make_tmp_dir!("desktop-receipts")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  defp start!(home), do: start_supervised!({Receipts, home: home, name: nil}, id: make_ref())

  defp receipt(n) do
    %{
      "invocation_id" => "inv-#{n}",
      "action" => "notify",
      "status" => "ok",
      "finished_at" => "2026-10-27T09:00:00Z",
      "args_sha256" => String.duplicate("a", 64),
      "result_sha256" => String.duplicate("b", 64)
    }
  end

  defp lines(home), do: home |> Receipts.path() |> File.read!() |> String.split("\n", trim: true)

  test "a receipt is one private line of hashes, looked up by invocation id", %{home: home} do
    receipts = start!(home)
    assert :ok = Receipts.record(receipts, receipt(1))

    assert Receipts.lookup(receipts, ["inv-1", "inv-404"]) == [receipt(1)]
    assert [line] = lines(home)
    assert Jason.decode!(line) == receipt(1)

    assert File.stat!(Receipts.path(home)).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(Path.join(home, "device")).mode |> Bitwise.band(0o777) == 0o700
  end

  test "only the newest 1,000 are kept, in memory and on disk across a restart", %{home: home} do
    receipts = start!(home)
    total = Receipts.max() + 150

    for n <- 1..total, do: :ok = Receipts.record(receipts, receipt(n))

    oldest = for n <- 1..150, do: "inv-#{n}"
    newest = for n <- 151..total, do: "inv-#{n}"
    assert Receipts.lookup(receipts, oldest) == []
    assert length(Receipts.lookup(receipts, newest)) == Receipts.max()
    assert length(lines(home)) <= Receipts.max() + 100
  end

  test "a restart reads back the newest 1,000 and nothing older", %{home: home} do
    first = start_supervised!({Receipts, home: home, name: nil}, id: :first)
    for n <- 1..(Receipts.max() + 150), do: :ok = Receipts.record(first, receipt(n))
    :ok = stop_supervised!(:first)

    again = start_supervised!({Receipts, home: home, name: nil}, id: :again)
    assert Receipts.lookup(again, ["inv-150"]) == []
    assert Receipts.lookup(again, ["inv-151", "inv-1150"]) == [receipt(151), receipt(1150)]
    assert length(lines(home)) <= Receipts.max() + 100
  end

  test "a line torn by a crash is logged and skipped", %{home: home} do
    path = Receipts.path(home)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(receipt(1)) <> "\n" <> ~s({"invocation_id":"inv-2","act))

    log =
      capture_log(fn ->
        receipts = start!(home)
        assert Receipts.lookup(receipts, ["inv-1", "inv-2"]) == [receipt(1)]
      end)

    assert log =~ "an unreadable line skipped"
  end

  test "a receipt missing a field, or with another status, is refused before it is written",
       %{home: home} do
    receipts = start!(home)

    assert_raise ArgumentError, fn ->
      Receipts.record(receipts, Map.delete(receipt(1), "args_sha256"))
    end

    assert_raise ArgumentError, fn ->
      Receipts.record(receipts, %{receipt(1) | "status" => "maybe"})
    end

    refute File.exists?(Receipts.path(home))
  end
end
