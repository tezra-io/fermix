#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8"]
# ///
"""Specs for the halden_ops fixture MCP server (cap_tool_discovery), driven over
stdio exactly as the daemon drives it: one JSON-RPC message per line."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
SERVER = HERE.parent / "suites" / "capability" / "fixtures" / "mcp" / "halden_ops.py"
sys.path.insert(0, str(SERVER.parent))

import halden_ops  # noqa: E402


def _session(state_dir, *messages):
    """Send `messages` to a fresh server process; return its responses by id."""
    lines = "".join(json.dumps(m) + "\n" for m in messages)
    proc = subprocess.run(["/usr/bin/env", "python3", str(SERVER), "--state-dir", str(state_dir)],
                          input=lines, capture_output=True, text=True, timeout=20, check=True)
    responses = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
    return {r["id"]: r for r in responses}


def _call(msg_id, name, arguments):
    return {"jsonrpc": "2.0", "id": msg_id, "method": "tools/call",
            "params": {"name": name, "arguments": arguments}}


def _payload(response):
    result = response["result"]
    return json.loads(result["content"][0]["text"]), result["isError"]


def test_the_handshake_lists_ten_tools_and_echoes_the_protocol(tmp_path):
    out = _session(tmp_path,
                   {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                    "params": {"protocolVersion": "2025-03-26", "capabilities": {}}},
                   {"jsonrpc": "2.0", "method": "notifications/initialized"},
                   {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    assert out[1]["result"]["protocolVersion"] == "2025-03-26"
    names = [tool["name"] for tool in out[2]["result"]["tools"]]
    assert len(names) == 10 and "shipment_status" in names and "ledger_add_entry" in names
    assert len(out) == 2                      # the notification got no response


def test_shipment_status_returns_the_shared_derivation(tmp_path):
    out = _session(tmp_path, _call(1, "shipment_status", {"tracking_id": "HX-4417"}))
    payload, is_error = _payload(out[1])
    assert not is_error and payload == halden_ops.shipment_facts("HX-4417")


def test_a_guessed_ledger_shape_is_refused_and_the_schema_shape_is_recorded(tmp_path):
    guess = {"date": "2027-03-03", "amount_cents": 42.5, "category": "food", "memo": "r1"}
    right = {"date": "2027-03-03", "amount_cents": 4250, "category": "meals", "memo": "r1"}
    out = _session(tmp_path, _call(1, "ledger_add_entry", guess),
                   _call(2, "ledger_add_entry", right),
                   _call(3, "ledger_list", {"month": "2027-03"}))
    refused, refused_error = _payload(out[1])
    assert refused_error and "amount_cents" in refused["error"]
    accepted, accepted_error = _payload(out[2])
    assert not accepted_error and accepted["recorded"] == right
    listed, _ = _payload(out[3])
    assert [e["amount_cents"] for e in listed["entries"]] == [4250]
    assert (tmp_path / "ledger.jsonl").is_file()


def test_an_integral_float_amount_is_accepted_as_cents(tmp_path):
    out = _session(tmp_path, _call(1, "ledger_add_entry",
                                   {"date": "2027-03-03", "amount_cents": 4250.0,
                                    "category": "meals", "memo": "r2"}))
    payload, is_error = _payload(out[1])
    assert not is_error and payload["recorded"]["amount_cents"] == 4250


def test_unknown_methods_and_tools_fail_loud_without_killing_the_server(tmp_path):
    out = _session(tmp_path, {"jsonrpc": "2.0", "id": 1, "method": "resources/list"},
                   _call(2, "no_such_tool", {}),
                   {"jsonrpc": "2.0", "id": 3, "method": "ping"})
    assert out[1]["error"]["code"] == -32601
    assert _payload(out[2])[1] is True
    assert out[3]["result"] == {}


def test_a_state_write_failure_is_a_tool_error_not_a_crash(tmp_path):
    blocked = tmp_path / "file-not-dir"
    blocked.write_text("x")
    out = _session(blocked, _call(1, "ledger_add_entry",
                                  {"date": "2027-03-03", "amount_cents": 1, "category": "meals",
                                   "memo": "m"}),
                   {"jsonrpc": "2.0", "id": 2, "method": "ping"})
    payload, is_error = _payload(out[1])
    assert is_error and "state write failed" in payload["error"]
    assert out[2]["result"] == {}


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
