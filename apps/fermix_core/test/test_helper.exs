# capture_log: passing tests stay silent — this suite intentionally logs many
# error/warning lines while exercising failure paths, which CI renders as a
# wall of red. A failing test still prints its captured log.
ExUnit.start(capture_log: true)
