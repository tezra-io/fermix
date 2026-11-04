"""Desktop corpus library (M86 P0): native fixture applications, judged by what
they recorded about themselves, counted from the daemon's own traces.

Composition order a runner follows: `corpus` loads and validates the task list
and renders each task for one fixture, `fixture` starts that application on a
fresh state file and stops it, the turn is driven through `evallib.driver`,
`oracle` reads the state file and evaluates the task's clauses, and `cu_trace`
selects the turn's trace rows and counts model calls, images and computer-use
failures. `cu_trace` is also the classifier `cu_baseline.py` runs over every
turn a machine recorded.
"""

__all__ = ["corpus", "fixture", "oracle", "cu_trace"]
