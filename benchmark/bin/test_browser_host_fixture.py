#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8.4"]
# ///
"""Specs for the fake Fermix app (`browser_host_fixture.py`) the `browser_host`
and `browser_sign_in` suites attach to a dev daemon: the protocol it declares
and the two sign-in requests it answers as the Mac app does. Driven in
process, with no socket, daemon or spend.
Run: `uv run bin/test_browser_host_fixture.py`."""
from __future__ import annotations

import json
import os
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import browser_host_fixture as fixture  # noqa: E402

ENGINE_PRIV = os.path.join(HERE, "..", "..", "apps", "fermix_core", "priv", "browser_host")


def host(**kwargs) -> fixture.FakeHost:
    defaults = dict(
        fail_after=None,
        fail_reason="host_unavailable",
        fail_message="the Mac is locked",
        cancel_after=None,
        cancel_reason="cancelled by the person",
        host_version="0.0.0-eval",
        profile_id="fermix-eval",
    )
    return fixture.FakeHost(**{**defaults, **kwargs})


def test_it_declares_the_engines_current_protocol():
    with open(os.path.join(ENGINE_PRIV, "protocol.schema.json")) as stream:
        schema = json.load(stream)
    assert fixture.PROTOCOL_VERSION == schema["x-protocol-version"]


def test_a_login_page_is_served_over_https_with_both_fields():
    fake = host(login_page=True)
    opened = fake.answer("tab.open", {"task_id": "task-1", "url": "https://example.com/login", "observe": True})
    assert opened["url"].startswith("https://")
    refs = {node.get("backendDOMNodeId") for node in opened["page"]["nodes"]}
    assert {fixture.USERNAME_REF, fixture.PASSWORD_REF} <= refs


def test_login_for_answers_the_saved_login_by_key():
    fake = host(login_page=True, saved_logins={"Example.com": "person@example.com"})
    for site in ["example.com", "www.example.com", "EXAMPLE.com."]:
        assert fake.answer("page.login_for", {"tab_id": "t1", "site": site}) == {
            "login_site": "example.com",
            "username": "person@example.com",
        }


def test_a_sign_in_host_of_its_own_uses_the_closest_parent_domains_login():
    saved = {"example.com": "person@example.com", "b.example.com": "b-person@example.com"}
    accounts = host(login_page=True, login_url="https://accounts.example.com/login", saved_logins=saved)
    assert accounts.answer("page.login_for", {"tab_id": "t1", "site": "accounts.example.com"}) == {
        "login_site": "example.com",
        "username": "person@example.com",
    }
    nested = host(login_page=True, login_url="https://a.b.example.com/login", saved_logins=saved)
    assert nested.answer("page.login_for", {"tab_id": "t1", "site": "a.b.example.com"})["login_site"] == "b.example.com"
    own = host(login_page=True, login_url="https://b.example.com/login", saved_logins=saved)
    assert own.answer("page.login_for", {"tab_id": "t1", "site": "b.example.com"})["login_site"] == "b.example.com"


def test_the_login_page_is_served_at_the_login_url():
    fake = host(login_page=True, login_url="https://accounts.example.com/login")
    opened = fake.answer("tab.open", {"task_id": "task-1", "url": "https://accounts.example.com/login", "observe": True})
    assert opened["url"] == "https://accounts.example.com/login"


@pytest.mark.parametrize(
    "saved, url, site, reason",
    [
        ({}, fixture.LOGIN_URL, "example.com", "sign_in_no_login"),
        ({"example.com": "person@example.com"}, fixture.LOGIN_URL, "github.com", "sign_in_wrong_site"),
        ({"accounts.example.com": "person@example.com"}, fixture.LOGIN_URL, "example.com", "sign_in_no_login"),
        ({"example.com": "person@example.com"}, "https://evilexample.com/login", "evilexample.com", "sign_in_no_login"),
        (
            {"example.com": "person@example.com"},
            "https://example.com.evil.example/login",
            "example.com.evil.example",
            "sign_in_no_login",
        ),
    ],
)
def test_login_for_refuses_as_the_app_does(saved, url, site, reason):
    fake = host(login_page=True, login_url=url, saved_logins=saved)
    with pytest.raises(fixture.Refusal) as refused:
        fake.answer("page.login_for", {"tab_id": "t1", "site": site})
    assert refused.value.reason == reason
    assert "person@example.com" not in refused.value.message


def test_sign_in_names_what_it_filled_in_order_and_nothing_else():
    fake = host(login_page=True, saved_logins={"example.com": "person@example.com"})
    frame = {
        "tab_id": "t1",
        "site": "example.com",
        "login_site": "example.com",
        "password_ref": fixture.PASSWORD_REF,
        "username_ref": fixture.USERNAME_REF,
        "observe": False,
    }
    result = fake.answer("page.sign_in", frame)
    assert result == {"url": fixture.LOGIN_URL, "title": "Sign in to Example", "filled": ["username", "password"]}

    alone = {k: v for k, v in frame.items() if k != "password_ref"}
    assert fake.answer("page.sign_in", alone)["filled"] == ["username"]


def test_sign_in_refuses_a_field_that_is_not_the_forms():
    fake = host(login_page=True, saved_logins={"example.com": "person@example.com"})
    frame = {"tab_id": "t1", "site": "example.com", "login_site": "example.com", "password_ref": 13, "observe": False}
    with pytest.raises(fixture.Refusal) as refused:
        fake.answer("page.sign_in", frame)
    assert refused.value.reason == "sign_in_field"


def test_saved_login_flags_parse_and_refuse_a_malformed_one():
    assert fixture.saved_login_arg("example.com=person@example.com") == ("example.com", "person@example.com")
    with pytest.raises(Exception):
        fixture.saved_login_arg("example.com")


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
