#!/usr/bin/env python3
"""Fixture MCP server for the tool-discovery capability suite: a fictional supply
company ("Halden Supply") with ten tools, served over stdio (newline-delimited
JSON-RPC 2.0), standard library only.

Why it exists: Fermix defers plugin and MCP tool schemas (names in the prompt,
schemas on demand through tool_search / tool_describe / tool_call). A disposable
eval home has no plugins, so without a server of its own nothing there is ever
deferred and the per-model sweep cannot tell whether a model can reach a tool it
has to discover. Every value here is invented.

The read tools derive their answers from the request (`shipment_facts`), so a
reply that contains them proves the tool ran: there is nothing to guess and
nothing to remember from training. The checkers import `shipment_facts` from
this file, so the server and the grader cannot drift. `ledger_add_entry`
validates its arguments the way a real API does, so a model that guesses the
schema gets an error it must recover from, and its success response echoes the
recorded entry for the checker to read from the trace.

Usage: halden_ops.py --state-dir DIR   (DIR is created on first write)
Kept 3.9-compatible: it runs under whatever python3 the daemon's PATH resolves.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import sys

SERVER_NAME = "halden_ops"
SERVER_VERSION = "1.0.0"
DEFAULT_PROTOCOL = "2025-06-18"
CARRIERS = ("Northwind Freight", "Bluegate Courier", "Kestrel Logistics", "Tidewater Express")
STATUSES = ("in transit", "out for delivery", "held at the depot")
ETA_BASE = datetime.date(2027, 4, 1)
CATEGORIES = ("meals", "travel", "software", "office", "shipping")
ON_CALL = "Robin Vale"
SITES = {"north": "Mon-Fri 07:00-18:00", "harbor": "Mon-Sat 06:00-20:00",
         "eastgate": "Tue-Sat 09:00-17:00"}
_DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
_MONTH_RE = re.compile(r"^\d{4}-\d{2}$")


def _digest(text: str) -> int:
    return int(hashlib.sha256(text.strip().upper().encode("utf-8")).hexdigest()[:12], 16)


def shipment_facts(tracking_id: str) -> dict:
    """The one definition of a shipment's facts, shared with the checker."""
    h = _digest(tracking_id)
    eta = ETA_BASE + datetime.timedelta(days=h % 20)
    return {"tracking_id": tracking_id.strip(), "carrier": CARRIERS[h % len(CARRIERS)],
            "status": STATUSES[(h // 7) % len(STATUSES)], "eta": eta.isoformat()}


# --- tools ------------------------------------------------------------------

def _schema(properties: dict, required: list) -> dict:
    return {"type": "object", "properties": properties, "required": required,
            "additionalProperties": False}


TOOLS = [
    {"name": "shipment_status",
     "description": "Current carrier, status and estimated delivery date of a Halden shipment.",
     "inputSchema": _schema({"tracking_id": {"type": "string", "description": "Tracking number"}},
                            ["tracking_id"])},
    {"name": "ledger_add_entry",
     "description": "Record an expense in the Halden ledger.",
     "inputSchema": _schema({
         "date": {"type": "string", "description": "Expense date, YYYY-MM-DD"},
         "amount_cents": {"type": "integer", "minimum": 1,
                          "description": "Amount in integer cents (12.50 -> 1250)"},
         "category": {"type": "string", "enum": list(CATEGORIES)},
         "memo": {"type": "string", "description": "Free text, e.g. a receipt number"}},
         ["date", "amount_cents", "category", "memo"])},
    {"name": "ledger_list",
     "description": "List ledger entries for one month.",
     "inputSchema": _schema({"month": {"type": "string", "description": "YYYY-MM"}}, ["month"])},
    {"name": "inventory_lookup",
     "description": "Units on hand for a Halden SKU.",
     "inputSchema": _schema({"sku": {"type": "string"}}, ["sku"])},
    {"name": "price_quote",
     "description": "Unit price and total for a SKU at a quantity.",
     "inputSchema": _schema({"sku": {"type": "string"},
                             "quantity": {"type": "integer", "minimum": 1}}, ["sku", "quantity"])},
    {"name": "invoice_status",
     "description": "Whether a Halden invoice is paid, due or overdue.",
     "inputSchema": _schema({"invoice_id": {"type": "string"}}, ["invoice_id"])},
    {"name": "supplier_contact",
     "description": "Account manager and email for a Halden supplier.",
     "inputSchema": _schema({"supplier": {"type": "string"}}, ["supplier"])},
    {"name": "warehouse_hours",
     "description": "Opening hours of a Halden warehouse site.",
     "inputSchema": _schema({"site": {"type": "string", "enum": sorted(SITES)}}, ["site"])},
    {"name": "return_label_create",
     "description": "Create a return shipping label for an order.",
     "inputSchema": _schema({"order_id": {"type": "string"}}, ["order_id"])},
    {"name": "team_on_call",
     "description": "Who is on call for Halden operations this week.",
     "inputSchema": _schema({}, [])},
]


class ToolError(Exception):
    """A refusal the caller sees as an `isError` result, never a crash."""


def _require_str(args: dict, key: str) -> str:
    value = args.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ToolError(f"{key} must be a non-empty string")
    return value.strip()


def _ledger_path(state_dir: str) -> str:
    return os.path.join(state_dir, "ledger.jsonl")


def _add_entry(args: dict, state_dir: str) -> dict:
    date = _require_str(args, "date")
    if not _DATE_RE.match(date):
        raise ToolError("date must be YYYY-MM-DD")
    datetime.date.fromisoformat(date)
    amount = args.get("amount_cents")
    if isinstance(amount, float) and amount.is_integer():
        amount = int(amount)                      # JSON Schema `integer` admits 4250.0
    if isinstance(amount, bool) or not isinstance(amount, int) or amount < 1:
        raise ToolError("amount_cents must be a positive integer number of cents (12.50 -> 1250)")
    category = args.get("category")
    if category not in CATEGORIES:
        raise ToolError(f"category must be one of: {', '.join(CATEGORIES)}")
    entry = {"date": date, "amount_cents": amount, "category": category,
             "memo": _require_str(args, "memo")}
    entry_id = "L-" + hashlib.sha256(json.dumps(entry, sort_keys=True).encode()).hexdigest()[:8]
    os.makedirs(state_dir, exist_ok=True)
    with open(_ledger_path(state_dir), "a", encoding="utf-8") as fh:
        fh.write(json.dumps({"entry_id": entry_id, **entry}) + "\n")
    return {"entry_id": entry_id, "recorded": entry}


def _list_entries(args: dict, state_dir: str) -> dict:
    month = _require_str(args, "month")
    if not _MONTH_RE.match(month):
        raise ToolError("month must be YYYY-MM")
    entries = []
    if os.path.exists(_ledger_path(state_dir)):
        with open(_ledger_path(state_dir), encoding="utf-8") as fh:
            entries = [json.loads(line) for line in fh if line.strip()]
    return {"month": month, "entries": [e for e in entries if e["date"].startswith(month)]}


def _simple(name: str, args: dict) -> dict:
    """The read-only tools whose answers derive from their input."""
    if name == "shipment_status":
        return shipment_facts(_require_str(args, "tracking_id"))
    if name == "inventory_lookup":
        sku = _require_str(args, "sku")
        return {"sku": sku, "units_on_hand": _digest(sku) % 400}
    if name == "price_quote":
        sku = _require_str(args, "sku")
        quantity = args.get("quantity")
        if isinstance(quantity, bool) or not isinstance(quantity, int) or quantity < 1:
            raise ToolError("quantity must be a positive integer")
        unit_cents = 250 + _digest(sku) % 4000
        return {"sku": sku, "unit_cents": unit_cents, "total_cents": unit_cents * quantity}
    if name == "invoice_status":
        invoice = _require_str(args, "invoice_id")
        return {"invoice_id": invoice, "status": ("paid", "due", "overdue")[_digest(invoice) % 3]}
    if name == "supplier_contact":
        supplier = _require_str(args, "supplier")
        handle = re.sub(r"[^a-z]", "", supplier.lower())[:12] or "supplier"
        return {"supplier": supplier, "account_manager": "Sam Ortega",
                "email": f"{handle}@suppliers.halden.example"}
    if name == "warehouse_hours":
        site = args.get("site")
        if site not in SITES:
            raise ToolError(f"site must be one of: {', '.join(sorted(SITES))}")
        return {"site": site, "hours": SITES[site]}
    if name == "team_on_call":
        return {"on_call": ON_CALL, "week_of": "this week"}
    raise ToolError(f"unknown tool: {name}")


def call_tool(name: str, args: dict, state_dir: str) -> dict:
    if not isinstance(args, dict):
        raise ToolError("arguments must be an object")
    if name == "ledger_add_entry":
        return _add_entry(args, state_dir)
    if name == "ledger_list":
        return _list_entries(args, state_dir)
    if name == "return_label_create":
        order = _require_str(args, "order_id")
        return {"order_id": order, "label_id": "R-" + format(_digest(order) % 10**6, "06d")}
    return _simple(name, args)


# --- JSON-RPC over stdio ----------------------------------------------------

def handle(message: dict, state_dir: str) -> dict | None:
    """One request in, one response out (None for a notification)."""
    method, msg_id = message.get("method"), message.get("id")
    if msg_id is None:
        return None
    if method == "initialize":
        params = message.get("params") or {}
        result = {"protocolVersion": params.get("protocolVersion") or DEFAULT_PROTOCOL,
                  "capabilities": {"tools": {"listChanged": False}},
                  "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": TOOLS}
    elif method == "tools/call":
        params = message.get("params") or {}
        result = _tool_result(params.get("name"), params.get("arguments") or {}, state_dir)
    else:
        return {"jsonrpc": "2.0", "id": msg_id,
                "error": {"code": -32601, "message": f"method not found: {method}"}}
    return {"jsonrpc": "2.0", "id": msg_id, "result": result}


def _tool_result(name, args, state_dir: str) -> dict:
    try:
        payload, is_error = call_tool(str(name), args, state_dir), False
    except (ToolError, ValueError) as exc:
        payload, is_error = {"error": str(exc)}, True
    except OSError as exc:
        payload, is_error = {"error": f"halden_ops state write failed: {exc}"}, True
    return {"content": [{"type": "text", "text": json.dumps(payload)}], "isError": is_error}


def serve(state_dir: str) -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except ValueError:
            response = {"jsonrpc": "2.0", "id": None,
                        "error": {"code": -32700, "message": "parse error"}}
        else:
            response = handle(message, state_dir) if isinstance(message, dict) else None
        if response is not None:
            sys.stdout.write(json.dumps(response) + "\n")
            sys.stdout.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description="halden_ops fixture MCP server (stdio)")
    parser.add_argument("--state-dir", required=True)
    serve(os.path.abspath(parser.parse_args().state_dir))


if __name__ == "__main__":
    main()
