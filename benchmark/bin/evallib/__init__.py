"""Fermix E2E eval runner library.

Drives realistic queries into the Opik-enabled Fermix dev daemon, pulls each
turn's trace from local Opik, grades it against YAML-declared expectations
(structural gates + optional LLM judge), and renders MD/HTML/JSON reports.
"""

__all__ = ["config", "suites", "opik", "driver", "grade", "judge", "report",
           "scoring", "aggregate", "experiments", "leaderboard", "uplift",
           "checker", "safe_rm"]
