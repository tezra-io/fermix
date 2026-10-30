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
