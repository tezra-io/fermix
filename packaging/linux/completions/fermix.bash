# bash completion for fermix, installed by the fermix package.
# The verb list is the one `fermix help` prints; a test keeps them in step.

_fermix() {
  local verbs="setup auth ask chat run sandbox grant revoke service start stop restart status health voice acp browser browser-bridge agents capabilities skills plugins pair devices memory logs upgrade uninstall migrate-to-app doctor diagnostics version help"
  local current previous
  current="${COMP_WORDS[COMP_CWORD]}"
  previous="${COMP_WORDS[COMP_CWORD - 1]}"

  if [ "$COMP_CWORD" -eq 1 ]; then
    mapfile -t COMPREPLY < <(compgen -W "$verbs" -- "$current")
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    setup)
      mapfile -t COMPREPLY < <(compgen -W "--web --cli --terminal --no-browser --no-service --user --system --rotate-token --print-state --reconfigure --migrate-secrets --import-codex --provider --default-model --reasoning-effort --fast --no-fast" -- "$current")
      ;;
    auth)
      mapfile -t COMPREPLY < <(compgen -W "login status logout --no-browser --port --timeout" -- "$current")
      ;;
    ask | chat)
      mapfile -t COMPREPLY < <(compgen -W "--stdin --session --timeout --json" -- "$current")
      ;;
    service)
      if [ "$previous" = service ]; then
        mapfile -t COMPREPLY < <(compgen -W "install uninstall status run" -- "$current")
      else
        mapfile -t COMPREPLY < <(compgen -W "--json --home --port --user --system" -- "$current")
      fi
      ;;
    start | stop)
      mapfile -t COMPREPLY < <(compgen -W "--user --system" -- "$current")
      ;;
    restart)
      mapfile -t COMPREPLY < <(compgen -W "--json --when-idle --user --system" -- "$current")
      ;;
    status)
      mapfile -t COMPREPLY < <(compgen -W "--full --json" -- "$current")
      ;;
    health | agents | voice)
      mapfile -t COMPREPLY < <(compgen -W "--json" -- "$current")
      ;;
    acp)
      mapfile -t COMPREPLY < <(compgen -W "forget --all" -- "$current")
      ;;
    browser)
      mapfile -t COMPREPLY < <(compgen -W "bridge install uninstall status --browser --extension-id" -- "$current")
      ;;
    browser-bridge)
      mapfile -t COMPREPLY < <(compgen -W "--manifest" -- "$current")
      ;;
    capabilities)
      mapfile -t COMPREPLY < <(compgen -W "--kind --json" -- "$current")
      ;;
    skills)
      mapfile -t COMPREPLY < <(compgen -W "list view reload --json" -- "$current")
      ;;
    plugins)
      mapfile -t COMPREPLY < <(compgen -W "list catalog install enable disable auth --json" -- "$current")
      ;;
    devices)
      mapfile -t COMPREPLY < <(compgen -W "list revoke" -- "$current")
      ;;
    memory)
      mapfile -t COMPREPLY < <(compgen -W "review restore --now --conversation --json" -- "$current")
      ;;
    logs)
      mapfile -t COMPREPLY < <(compgen -W "-f -n" -- "$current")
      ;;
    upgrade)
      mapfile -t COMPREPLY < <(compgen -W "--check" -- "$current")
      ;;
    migrate-to-app)
      mapfile -t COMPREPLY < <(compgen -W "--yes" -- "$current")
      ;;
    doctor)
      mapfile -t COMPREPLY < <(compgen -W "--full" -- "$current")
      ;;
    diagnostics)
      mapfile -t COMPREPLY < <(compgen -W "export --offline --json" -- "$current")
      ;;
    *)
      COMPREPLY=()
      ;;
  esac
}

complete -F _fermix fermix
