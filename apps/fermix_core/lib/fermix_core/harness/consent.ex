defmodule FermixCore.Harness.Consent do
  @moduledoc """
  The first-use consent gate for the coding harness (owner decision 2026-07-21,
  simplified to a setup decision 2026-07-25, design §23.3).

  Consent protects **first-use awareness** ("this spends your subscription and
  lets an autonomous agent edit your repo"), not a security boundary — guests,
  sub-agent workers, and unauthorized cron are refused by
  `Harness.Authorization` regardless. Awareness is served by an explicit setup
  toggle, so this module is a config read plus actionable guidance: consent is
  granted in Setup → Coding Agents or by setting `[fermix_core.harness] approved`
  (default `false`) in config. Two knobs, two jobs — `enabled` says the feature
  exists, `approved` says the owner consented on this machine; a permanent
  "never" is `enabled = false`, there is no third state.

  There is no mid-conversation consent prompt: the removed interactive path was
  the harness's only *stall* state (a pending token nothing could answer). And
  Fermix never grants consent itself — a self-grantable gate is decorative.

  `ensure_approved/0` is called by each run tool's `execute/2` AFTER
  authorization and BEFORE any ledger/manager work. Unapproved returns
  `{:error, :consent_required}`; a **scheduled origin** is additionally ledgered
  `blocked/:consent_required` and delivered by the caller, carrying
  `scheduled_guidance/0`. `approved` is also part of the advertise gate (§23.4),
  so an unapproved machine advertises no run tool at all — the refusal is only
  reachable by a by-name dispatch, and the tool-boundary message tells the caller
  to do the work directly instead of dead-ending.
  """

  alias FermixCore.Harness.Config

  @type reason :: :consent_required

  @doc """
  Gate a harness launch: `:ok` when the owner has approved coding agents on this
  machine, `{:error, :consent_required}` otherwise.
  """
  @spec ensure_approved() :: :ok | {:error, :consent_required}
  def ensure_approved do
    if Config.approved?(), do: :ok, else: {:error, :consent_required}
  end

  @doc """
  The guidance delivered to the owner when a launch is blocked
  `:consent_required` — where coding agents are approved on this machine.
  """
  @spec scheduled_guidance() :: String.t()
  def scheduled_guidance do
    "Coding agents are not yet approved on this machine. Approve them in " <>
      "Setup → Coding Agents, or set [fermix_core.harness] approved = true in config."
  end
end
