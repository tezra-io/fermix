"""Terminal-Bench (Harbor) installed-agent adapter for Fermix.

⚠️  SKELETON — VERIFY the AbstractInstalledAgent method/property names against your
    installed terminal-bench version before running. Harbor's agent API has moved
    between releases; this encodes the *integration design*, not pinned signatures.
    Docs: https://www.tbench.ai/docs/agent-introduction

Why this is a CLEAN fit: Terminal-Bench scores the container's end-state with
per-task tests, and the agent is "installed from the command line" — exactly
Fermix's shape. Fermix is installed INSIDE the task container and solves with its
OWN shell/file/git tools (the goal: same toolset, swap the model behind it). No
tool-protocol bridging needed (unlike tau2/AppWorld — see ../RUNBOOK.md).

Integration design:
  1. install step: place the Fermix binary on PATH in the container + a minimal
     `config.toml` pinning the provider/model and enabling shell+sandbox; export
     the provider key as a container env var (Harbor passes `--env`).
  2. run step:   `fermix ask --timeout <ms> "<task instruction>"` in the task's
     working dir. Fermix's sandbox floor = the container workspace, so its file/
     shell tools mutate exactly the state Terminal-Bench tests.

Run (confirm flags per your version):
    tb run --agent-import-path bench.terminal_bench.fermix_agent:FermixAgent \\
           --model <model-id> --task-id <task>
"""
from __future__ import annotations

import os

# from terminal_bench.agents.installed_agents.abstract_installed_agent import AbstractInstalledAgent
# from terminal_bench.agents.agent_name import AgentName   # names vary by version


FERMIX_VERSION = os.environ.get("FERMIX_TBENCH_VERSION", "latest")


def install_script() -> str:
    """Shell run inside the task container before the agent acts. Installs Fermix
    and writes a minimal config. Pin FERMIX_TBENCH_* in the Harbor `--env` set."""
    return f"""
set -euo pipefail
# 1. Fermix binary (replace with your install channel — brew tap / release tarball / build)
curl -fsSL https://fermix.sh/install.sh | sh   # or COPY a prebuilt binary in
# 2. minimal config: pin provider+model, enable shell + sandbox at the workspace floor
mkdir -p "$HOME/.fermix"
cat > "$HOME/.fermix/config.toml" <<TOML
[fermix_core.providers.{os.environ.get('FERMIX_TBENCH_PROVIDER', 'openai')}]
primary = true
default_model = "${{FERMIX_TBENCH_MODEL}}"
[fermix_core.sandbox]
mode = "standard"
TOML
fermix start
"""


def exec_command(instruction: str, timeout_ms: int = 600_000) -> list[str]:
    """The command Harbor runs to drive one task."""
    return ["fermix", "ask", "--timeout", str(timeout_ms), instruction]


# --- the Harbor adapter (confirm the base class + overrides for your version) ---
#
# class FermixAgent(AbstractInstalledAgent):
#     @staticmethod
#     def name() -> str:
#         return "fermix"
#
#     @property
#     def _env(self) -> dict[str, str]:
#         # provider key + model, passed through from `tb run --env`
#         return {k: os.environ[k] for k in ("FERMIX_TBENCH_MODEL", "OPENAI_API_KEY")
#                 if k in os.environ}
#
#     def _install_agent_script(self) -> str:
#         return install_script()
#
#     def _run_agent_command(self, task_instruction: str) -> list[str]:
#         return exec_command(task_instruction)
#
# The two pure helpers above (install_script / exec_command) hold the real
# integration logic and are import-safe without terminal-bench installed, so they
# can be unit-checked; the class is the thin Harbor binding.
