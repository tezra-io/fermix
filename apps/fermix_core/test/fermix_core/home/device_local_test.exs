defmodule FermixCore.Home.DeviceLocalTest do
  use ExUnit.Case, async: true

  alias FermixCore.Home.DeviceLocal

  test "every entry names a pattern and one line of reason" do
    for %{pattern: pattern, reason: reason} <- DeviceLocal.excluded() do
      assert is_binary(pattern) and pattern != ""
      assert is_binary(reason) and reason != "" and not String.contains?(reason, "\n"), pattern
    end

    patterns = Enum.map(DeviceLocal.excluded(), & &1.pattern)
    assert patterns == Enum.uniq(patterns)
  end

  test "every entry says whether a return keeps it, and there is no third answer" do
    for %{pattern: pattern, return: return} <- DeviceLocal.excluded() do
      assert return in [:keep, :drop], pattern
    end
  end

  # A return (Always On's move back) puts the server's home in place of the
  # retired copy here and keeps this machine's own paths, at any depth.
  test "a return keeps what this machine's hardware, account and apps own, at depth" do
    for path <- [
          "logs/fermix.log",
          "traces/2026-10-27/run.jsonl",
          "config.toml.lock",
          "plugins/.lock",
          "auth.json.broken.1793083733",
          "config.toml.pre-m5",
          "device",
          "device/provision/srv-1.json",
          "device/return.json",
          "snapshots/2026-10-30T02:00:00Z-e5.fxsnap",
          "engine-owner.json",
          "setup-token",
          "setup-launch-token.json",
          "secret_key_base",
          "upgrades.jsonl",
          "upgrade.staging/fermix.upgrade.tmp",
          ".previous",
          "bin/fermix-browser-bridge-chrome",
          "grants/grant-1793083733-1.json",
          "browser/profiles",
          "browser/profiles/owner/default/Cookies",
          "imessage/cursor",
          "harness/runs",
          "harness/runs/run-1/events.jsonl",
          "models/stt/whisper/base/model.bin",
          "companion/media/ref.png",
          "workspace/.cache/npm/index",
          "acp_identities/peer.json.broken.1793083733",
          "plugins/compux/1.2.0/macos/Fermix.app/Contents/Info.plist",
          "plugins/stt/bin/macos/fermix-stt",
          "plugins/meetbot/profile/Cookies",
          "plugins/imessage_helper/1.0.0/macos-universal/x"
        ] do
      assert DeviceLocal.kept_through_return?(path), path
    end
  end

  test "a return drops the ended tenure's bookkeeping, sockets and interrupted writes" do
    for path <- [
          "moved.json",
          ".move/phase.json",
          "device/desktop.json",
          "device/desktop_key",
          "candidate/state.json",
          "mobile/candidates.json",
          "mobile/enrollment.json",
          "plugins/reinstall.json",
          "daemon.sock",
          "mobile/bridge.sock",
          "mobile/dial-4f2a.sock",
          "tunnel-0a1b2c3d.sock",
          "auth.json.tmp.12",
          "mobile/devices.toml.tmp.3",
          "mobile/attachments-4.part",
          "mobile/media/b.part",
          "secrets/.OPENAI_API_KEY.991",
          "plugins/.staging/x",
          "plugins/run/default.token",
          "mobile/.identity-transaction",
          "mobile/uploads/a.part",
          "mobile/materialized/a.png",
          "acp_identities/peer.json.tmp.2",
          "bootstrap/main/IDENTITY.md.tmp-4",
          "plugins/installed/notes/current.tmp",
          "plugins/installed/notes/.1.0.0.replacing",
          "plugins/evidence/notes/.1.0.0.staging/sig"
        ] do
      refute DeviceLocal.kept_through_return?(path), path
    end
  end

  test "a kept path's own pattern names how deep it is, at most return_depth/0 names" do
    kept = for %{pattern: pattern, return: :keep} <- DeviceLocal.excluded(), do: pattern

    for pattern <- kept do
      refute String.starts_with?(pattern, "**"), pattern
      assert length(String.split(pattern, "/")) <= DeviceLocal.return_depth(), pattern
    end

    assert DeviceLocal.return_depth() in Enum.map(kept, &length(String.split(&1, "/")))
  end

  # What travels comes back from the server's copy, never from the retired one;
  # the parents of a kept path are not kept themselves.
  test "a return keeps nothing that travels, nor a kept path's parent" do
    for path <- [
          "config.toml",
          "memory.db",
          "memory.db-wal",
          "auth.json",
          "chatgpt_host.json",
          "secrets/OPENAI_API_KEY",
          "mobile/devices.toml",
          "journals/2026-10-27.md",
          "plugins/installed.json",
          "plugins",
          "harness",
          "browser",
          "workspace",
          "companion",
          "acp_identities/peer.json"
        ] do
      refute DeviceLocal.kept_through_return?(path), path
    end
  end

  test "what belongs to this machine is excluded, with everything beneath it" do
    for path <- [
          "logs",
          "logs/fermix.log",
          "logs/mcp/stdio-notes.stderr",
          "traces/2026-10-27/run.jsonl",
          "daemon.sock",
          "realtime.sock",
          "companion.sock",
          "acp.sock",
          "browser_bridge.sock",
          "browser_host.sock",
          "native_host.sock",
          "mobile/bridge.sock",
          "config.toml.lock",
          "auth.json.lock",
          "auth.json.b3BlbmFp.lock",
          "plugins/.lock",
          "auth.json.tmp.12",
          "auth.json.broken.1793083733",
          "config.toml.pre-m5",
          "moved.json",
          "engine-owner.json",
          "setup-token",
          "setup-launch-token.json",
          "secret_key_base",
          "upgrades.jsonl",
          "upgrade.staging/fermix.upgrade.tmp",
          ".previous",
          "bin/fermix-browser-bridge-chrome",
          "grants/grant-1793083733-1.json",
          "browser/profiles/owner/default/Cookies",
          "imessage/cursor",
          "imessage/helper/ledger.json",
          "harness/runs/run-1/events.jsonl",
          "models/stt/whisper/base/model.bin",
          "companion/media/ref.png",
          "workspace/.cache/npm/index",
          "mobile/.identity-transaction",
          "mobile/uploads/a.part",
          "mobile/materialized/a.png",
          "mobile/devices.toml.tmp.3",
          "mobile/primary_epoch.tmp",
          "mobile/attachments-4.part",
          "mobile/media/b.part",
          "secrets/.OPENAI_API_KEY.991",
          "acp_identities/peer.json.tmp.2",
          "acp_identities/peer.json.broken.1793083733",
          "bootstrap/main/IDENTITY.md.tmp-4",
          "plugins/.staging/x",
          "plugins/run/default.token",
          "plugins/compux/1.2.0/macos/Fermix.app/Contents/Info.plist",
          "plugins/stt/bin/macos/fermix-stt",
          "plugins/meetbot/profile/Cookies",
          "plugins/imessage_helper/1.0.0/macos-universal/x",
          "plugins/installed/notes/current.tmp",
          "plugins/installed/notes/.1.0.0.replacing",
          "plugins/evidence/notes/.1.0.0.staging/sig",
          "workspace/project/run.sock"
        ] do
      assert DeviceLocal.excluded?(path), path
    end
  end

  test "what makes the home the primary is kept, user files included" do
    for path <- [
          "config.toml",
          "memory.db",
          "memory.db-wal",
          "memory.db-shm",
          "auth.json",
          "chatgpt_host.json",
          "secrets/OPENAI_API_KEY",
          "mobile/gateway_key",
          "mobile/tls.key",
          "mobile/tls.crt",
          "mobile/iroh_key",
          "mobile/devices.toml",
          "mobile/primary_epoch",
          "mobile/attachments.json",
          "mobile/media/0a1b2c",
          "memory/main/MEMORY.md",
          "bootstrap/main/IDENTITY.md",
          "skills/notes/SKILL.md",
          "skills/_archive/notes@1793083733/SKILL.md",
          "journals/2026-10-27.md",
          "plugins/installed.json",
          "plugins/installed/notes/1.0.0/bin/run",
          "plugins/installed/notes/current",
          "plugins/evidence/notes/1.0.0/sig",
          "plugins/github/skills/github/SKILL.md",
          "acp_identities/peer.json",
          "job_runs/job_runs/run-1/output.md",
          "realtime/device_id",
          "browser/artifacts/owner/screenshot/a.png",
          "browser/downloads/owner/report.pdf",
          "workspace/meetings/m-1/transcript.md",
          "workspace/project/mix.lock",
          "workspace/project/notes.tmp.md",
          "workspace/logs/mine.txt"
        ] do
      refute DeviceLocal.excluded?(path), path
    end
  end
end
