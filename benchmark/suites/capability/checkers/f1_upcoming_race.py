#!/usr/bin/env python3
"""Checker (json): a live-web task about the real Formula 1 calendar, graded against
the calendar as it stands when the trial is graded, so no answer is stored anywhere.

Gold (`checker.expect`):
  calendar_url  season calendar URL with a {year} placeholder (Ergast-format JSON,
                e.g. https://api.jolpi.ca/ergast/f1/{year}.json)
  countries     the countries the user can travel to (Ergast's names: USA, Canada, ...)
  skip          how many upcoming races in those countries to pass over (1 = "not the
                next one, the one after")

The race picked is upcoming[skip] among races dated today or later, this season and
next. The reply must name its city or circuit and give its date in a common spelling.
A calendar that cannot be fetched or read raises: that is an evaluator failure (the
trial is invalid), never a zero for the model.
"""
import datetime
import json
import os
import re
import sys
import urllib.request

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402

MONTHS = ("january", "february", "march", "april", "may", "june", "july", "august",
          "september", "october", "november", "december")


def season(url_template, year):
    with urllib.request.urlopen(url_template.format(year=year), timeout=20) as resp:
        data = json.load(resp)
    return data["MRData"]["RaceTable"]["Races"]


def date_pattern(iso):
    """April 7, Apr. 7, 7 April, the 7th of April, 2027-04-07, 4/7."""
    _year, month, day = (int(part) for part in iso.split("-"))
    name = MONTHS[month - 1]
    word = rf"(?:{name}|{name[:3]}\.?)"
    num = rf"0?{day}(?:st|nd|rd|th)?"
    forms = [re.escape(iso), rf"{word}\s+{num}\b", rf"\b{num}\s+(?:of\s+)?{word}\b",
             rf"\b0?{month}/0?{day}\b"]
    return re.compile("|".join(forms), re.IGNORECASE)


ev = lib.evidence()
gold = lib.expected(ev)
today = datetime.date.today()
races = season(gold["calendar_url"], today.year) + season(gold["calendar_url"], today.year + 1)
upcoming = sorted((r for r in races
                   if r["Circuit"]["Location"]["country"] in gold["countries"]
                   and datetime.date.fromisoformat(r["date"]) >= today),
                  key=lambda r: r["date"])
if len(upcoming) <= gold["skip"]:
    raise SystemExit(f"calendar lists only {len(upcoming)} upcoming race(s) in {gold['countries']}")
race = upcoming[gold["skip"]]
place = race["Circuit"]["Location"]["locality"]
circuit = race["Circuit"]["circuitName"]
reply = ev.get("reply") or ""
if not (lib.term_present(reply, place) or lib.term_present(reply, circuit)):
    lib.refuse(f"reply does not name {race['raceName']} ({place}, {circuit})")
if not date_pattern(race["date"]).search(reply):
    lib.refuse(f"reply does not give the race date {race['date']}")
lib.emit(1.0, f"{race['raceName']} in {place} on {race['date']}")
