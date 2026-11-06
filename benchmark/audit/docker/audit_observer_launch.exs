Code.require_file("audit_observer.exs", __DIR__)
run_id = System.fetch_env!("FERMIX_AUDIT_RUN_ID")
token = System.fetch_env!("ANTHROPIC_API_KEY")

{:ok, _observer} =
  FermixAudit.Observer.start_link(
    run_id: run_id,
    token: token,
    prefix: "audit-#{run_id}",
    socket_path: "/home/audit/fermix/audit-observer.sock"
  )

Mix.Tasks.Fermix.Dev.run(["--no-web", "--no-realtime"])
