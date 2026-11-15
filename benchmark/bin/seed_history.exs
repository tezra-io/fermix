# Computer-history notes for the computers suite (M97 §8.4), in a disposable
# eval home seeded with --computers.
#
#   FERMIX_HOME=<eval home> mix run --no-start --no-compile benchmark/bin/seed_history.exs
#
# Runs after seed_capability_home.py, which reset memory.db and linked the two
# computers, and BEFORE the daemon starts (capability-daemon.sh `up` runs it when
# `eval-fixtures/computers.json` exists), so it is the only writer. Through the
# product's own call (`Repo.computer_history_insert_memory/2`) it writes notes as
# the home keeps them once its computers have sent their sittings:
#
#   * studio Mac, this morning 08:30-09:40 in the home's zone: the reply to the
#     Juniper Street lease renewal, drafted in Mail and Pages
#   * studio Mac, yesterday 14:00-15:10: the tomato seed order spreadsheet
#   * loft Linux, yesterday 10:15-11:05: the garden shed's build list, written
#     in Text Editor (a Linux computer records, M97 stage 4)
#   * this computer (the home's own machine), yesterday 16:00-16:45: the
#     electricity bill paid on the utility's site
# Times are the seed day's, in America/New_York, so "this morning" and
# "yesterday" name them; an eval run before 09:40 there sees the morning note
# still open-ended. It writes `eval-fixtures/computer_history.json` last. Every
# value here is invented.

defmodule SeedHistory do
  alias FermixCore.Memory.Config, as: MemoryConfig
  alias FermixCore.Memory.Repo

  @computers_manifest "eval-fixtures/computers.json"
  @manifest "eval-fixtures/computer_history.json"
  @studio "6f1c2a9e-3b7d-4c21-9a8e-1d2f3a4b5c6d"
  @loft "b47e0d93-5a1c-4f68-8e2b-7c9d1a3f6e05"
  @zone "America/New_York"

  def main([]) do
    home = eval_home!()
    same_database!(home)
    linked!(home)
    {:ok, _apps} = Application.ensure_all_started(:exqlite)
    {:ok, _repo} = Repo.start_link([])
    today = DateTime.now!(@zone) |> DateTime.to_date()
    yesterday = Date.add(today, -1)

    notes = [
      note(@studio, today, {~T[08:30:00], ~T[09:40:00]},
        "Drafted the reply to the Juniper Street lease renewal: accepted the new rent from " <>
          "March and asked the landlord to fix the porch light first.",
        ["com.apple.mail", "com.apple.iWork.Pages"], ["Re: Juniper Street lease renewal"]),
      note(@studio, yesterday, {~T[14:00:00], ~T[15:10:00]},
        "Built the tomato seed order in Numbers: twelve varieties, trimmed to a budget of " <>
          "sixty dollars, order not yet placed.",
        ["com.apple.iWork.Numbers"], ["Seed order 2027"]),
      note(@loft, yesterday, {~T[10:15:00], ~T[11:05:00]},
        "Wrote the build list for the garden shed: cedar boards, roofing felt and two hinges, " <>
          "with the lumber yard's quote still to come.",
        ["Text Editor"], ["shed-build-list.txt"]),
      note("", yesterday, {~T[16:00:00], ~T[16:45:00]},
        "Paid the electricity bill on the utility's website and saved the receipt.",
        ["com.google.Chrome"], ["Pay your bill — Riverbend Power"])
    ]

    ids = Enum.map(notes, &insert!/1)
    write_manifest!(home, %{notes: length(ids), studio_mac: @studio, loft_linux: @loft})
    IO.puts("seeded #{length(ids)} computer-history notes")
  end

  def main(_args),
    do: raise(ArgumentError, "usage: seed_history.exs (FERMIX_HOME set to an eval home)")

  defp note(computer, date, {from, to}, summary, apps, titles) do
    %{
      created_at: ms(date, to),
      provenance_from_ts: ms(date, from),
      provenance_to_ts: ms(date, to),
      summary: summary,
      apps: Jason.encode!(apps),
      sites: "[]",
      titles: Jason.encode!(titles),
      urls: "[]",
      event_count: 40,
      model: "eval-seed",
      computer_id: computer,
      sitting: "eval-#{computer}-#{Date.to_iso8601(date)}-#{Time.to_iso8601(from)}"
    }
  end

  defp ms(date, time),
    do: date |> DateTime.new!(time, @zone) |> DateTime.to_unix(:millisecond)

  defp insert!(memory) do
    {:ok, id} = Repo.computer_history_insert_memory(memory)
    id
  end

  # --- guards ------------------------------------------------------------------

  defp eval_home! do
    home = System.fetch_env!("FERMIX_HOME") |> Path.expand()
    leaf = home |> Path.basename() |> String.downcase()

    unless String.contains?(leaf, "eval") or String.contains?(leaf, "e2e") do
      raise "refusing to seed history outside a disposable eval home: #{home}"
    end

    home
  end

  defp same_database!(home) do
    opened = Path.expand(MemoryConfig.database_path())
    wanted = Path.expand(Path.join(home, "memory.db"))

    unless opened == wanted do
      raise "the helper would open #{opened}, not the eval home's #{wanted}"
    end
  end

  defp linked!(home) do
    linked? = fn id -> File.regular?(Path.join([home, "device", "computers", "#{id}.json"])) end

    unless File.regular?(Path.join(home, @computers_manifest)) and linked?.(@studio) and
             linked?.(@loft) do
      raise "the eval home has no studio Mac and loft Linux: seed it with --computers first"
    end
  end

  defp write_manifest!(home, manifest) do
    path = Path.join(home, @manifest)
    File.write!(path, Jason.encode!(manifest, pretty: true))
    File.chmod!(path, 0o600)
  end
end

SeedHistory.main(System.argv())
