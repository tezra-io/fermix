defmodule FermixCore.SkillCuration.Proposals do
  @moduledoc """
  Proposal store operations, tokens, and derived signature dispositions
  (MILESTONE_26_SKILL_CURATION §6.5).

  Proposal rows in memory.db are the only signature state: `declined`,
  `parked` (two or more uncleared expiries), and `pending`/`deferred` are derived
  from them, `created` from the ledger — there is deliberately no separate
  signatures table. `/skills unpark` clears rows out of the derivation via
  `disposition_cleared_at` while preserving their status for audit.
  """

  alias FermixCore.Memory.Repo

  # A deferred proposal gets this many delivery opportunities before expiring.
  @deferred_max_cycles 2
  # A signature expired this many times without an answer is parked.
  @park_expiries 2
  # At most one archive proposal per skill per this window (§6.5).
  @archive_cooldown_days 60

  @actionable_statuses ["pending", "deferred"]

  @type disposition :: %{
          created: Repo.skill_curation_ledger_row() | nil,
          declined: boolean(),
          parked: boolean(),
          open: boolean(),
          expired_count: non_neg_integer()
        }

  @spec generate_token() :: String.t()
  def generate_token do
    Base.encode32(:crypto.strong_rand_bytes(5), padding: false)
  end

  # The module's opts convention is `repo:` (the Reviewer shape); Repo's is
  # `server:`. Translate once here.
  defp repo_opts(opts), do: [server: Keyword.get(opts, :repo, Repo)]

  @spec insert(map(), keyword()) :: {:ok, Repo.skill_curation_proposal_row()} | {:error, term()}
  def insert(attrs, opts \\ []) when is_map(attrs) do
    attrs
    |> Map.put_new_lazy(:token, &generate_token/0)
    |> Repo.insert_skill_curation_proposal(repo_opts(opts))
  end

  @doc """
  Cycle-start sweep: pending rows that survived a full cadence period expire
  (superseded), deferred rows age, over-aged deferred rows expire.
  `supersession_days` is the cadence period, owned by the facade.
  """
  @spec sweep(DateTime.t(), pos_integer(), keyword()) ::
          {:ok, %{expired_pending: non_neg_integer(), expired_deferred: non_neg_integer()}}
          | {:error, term()}
  def sweep(%DateTime{} = now, supersession_days, opts \\ [])
      when is_integer(supersession_days) and supersession_days > 0 do
    Repo.sweep_skill_curation_proposals(
      now,
      supersession_days,
      @deferred_max_cycles,
      repo_opts(opts)
    )
  end

  @doc """
  Derived dispositions for every signature with any uncleared proposal row or
  ledger entry. `open` covers pending + deferred (already occupying the pipe).
  """
  @spec dispositions(keyword()) :: {:ok, %{String.t() => disposition()}} | {:error, term()}
  def dispositions(opts \\ []) do
    with {:ok, proposal_rows} <- Repo.list_skill_curation_proposals(%{}, repo_opts(opts)),
         {:ok, ledger_rows} <- Repo.list_skill_curation_ledger(%{}, repo_opts(opts)) do
      {:ok, derive_dispositions(proposal_rows, ledger_rows)}
    end
  end

  @spec deliverable_deferred(keyword()) ::
          {:ok, [Repo.skill_curation_proposal_row()]} | {:error, term()}
  def deliverable_deferred(opts \\ []) do
    Repo.list_skill_curation_proposals(%{statuses: ["deferred"]}, repo_opts(opts))
  end

  @doc "Deferred proposal enters delivery: `deferred -> pending`."
  @spec deliver_deferred(String.t(), DateTime.t(), keyword()) ::
          {:ok, Repo.skill_curation_proposal_row()} | {:error, term()}
  def deliver_deferred(token, %DateTime{} = now, opts \\ []) do
    Repo.transition_skill_curation_proposal(
      token,
      "deferred",
      "pending",
      %{},
      now,
      repo_opts(opts)
    )
  end

  @doc "Stamp delivery origin on a pending proposal (validated on action, §6.7)."
  @spec stamp_origin(String.t(), String.t(), String.t(), DateTime.t(), keyword()) ::
          {:ok, Repo.skill_curation_proposal_row()} | {:error, term()}
  def stamp_origin(token, channel, chat_id, %DateTime{} = now, opts \\ [])
      when is_binary(channel) and is_binary(chat_id) do
    Repo.transition_skill_curation_proposal(
      token,
      "pending",
      "pending",
      %{origin_channel: channel, origin_chat_id: chat_id},
      now,
      repo_opts(opts)
    )
  end

  @doc """
  Single-use approve. A deferred proposal the owner dug out of
  `/skills proposals` is approvable without waiting for its delivery cycle —
  the cap bounds proposal *delivery*, never an owner-initiated action.
  """
  @spec approve(String.t(), DateTime.t(), keyword()) ::
          {:ok, Repo.skill_curation_proposal_row()}
          | {:error, :not_found | {:invalid_status, String.t()} | term()}
  def approve(token, %DateTime{} = now, opts \\ []) do
    action(token, "approved", now, opts)
  end

  @spec decline(String.t(), DateTime.t(), keyword()) ::
          {:ok, Repo.skill_curation_proposal_row()}
          | {:error, :not_found | {:invalid_status, String.t()} | term()}
  def decline(token, %DateTime{} = now, opts \\ []) do
    action(token, "declined", now, opts)
  end

  @doc "Creation/update/archive execution failed: `approved -> failed`."
  @spec fail(String.t(), DateTime.t(), keyword()) ::
          {:ok, Repo.skill_curation_proposal_row()} | {:error, term()}
  def fail(token, %DateTime{} = now, opts \\ []) do
    Repo.transition_skill_curation_proposal(
      token,
      "approved",
      "failed",
      %{},
      now,
      repo_opts(opts)
    )
  end

  @doc """
  Clear declined/parked dispositions (§6.7 unpark) by token or exact
  signature so the next cycle may re-propose once.
  """
  @spec unpark(%{token: String.t()} | %{task_signature: String.t()}, DateTime.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def unpark(selector, %DateTime{} = now, opts \\ []) when is_map(selector) do
    Repo.clear_skill_curation_dispositions(selector, now, repo_opts(opts))
  end

  @doc """
  Whether an archive proposal for this skill is blocked: one is already open,
  or a terminal one (declined/expired, uncleared) sits inside the cool-down
  window — nobody gets nagged every cycle about the same unused skill.
  """
  @spec archive_proposal_blocked?(String.t(), DateTime.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def archive_proposal_blocked?(skill_name, %DateTime{} = now, opts \\ [])
      when is_binary(skill_name) do
    with {:ok, rows} <-
           Repo.list_skill_curation_proposals(
             %{kind: "archive_skill", skill_name: skill_name},
             repo_opts(opts)
           ) do
      {:ok, Enum.any?(rows, &archive_blocking?(&1, now))}
    end
  end

  @spec park_expiries() :: pos_integer()
  def park_expiries, do: @park_expiries

  @spec archive_cooldown_days() :: pos_integer()
  def archive_cooldown_days, do: @archive_cooldown_days

  defp action(token, to_status, now, opts) do
    Repo.transition_skill_curation_proposal(
      token,
      @actionable_statuses,
      to_status,
      %{},
      now,
      repo_opts(opts)
    )
  end

  defp archive_blocking?(%{status: status}, _now) when status in ["pending", "deferred"], do: true

  defp archive_blocking?(%{status: status, actioned_at: %DateTime{} = actioned}, now)
       when status in ["declined", "expired"] do
    DateTime.diff(now, actioned, :second) < @archive_cooldown_days * 86_400
  end

  defp archive_blocking?(_row, _now), do: false

  defp derive_dispositions(proposal_rows, ledger_rows) do
    base =
      Map.new(ledger_rows, fn row ->
        {row.task_signature, Map.put(empty_disposition(), :created, row)}
      end)

    Enum.reduce(proposal_rows, base, fn row, acc ->
      Map.update(
        acc,
        row.task_signature,
        fold_proposal(empty_disposition(), row),
        fn disposition ->
          fold_proposal(disposition, row)
        end
      )
    end)
    |> Map.new(fn {signature, disposition} ->
      {signature, Map.put(disposition, :parked, disposition.expired_count >= @park_expiries)}
    end)
    # A signature whose only rows are terminal non-answers (failed creations)
    # carries no disposition: a transient drafting failure must never bury the
    # idea the way an owner's decline does.
    |> Map.reject(fn {_signature, disposition} -> empty_disposition?(disposition) end)
  end

  defp empty_disposition?(disposition) do
    disposition.created == nil and not disposition.declined and not disposition.open and
      disposition.expired_count == 0
  end

  defp empty_disposition do
    %{created: nil, declined: false, parked: false, open: false, expired_count: 0}
  end

  defp fold_proposal(disposition, %{status: "declined"}), do: %{disposition | declined: true}

  defp fold_proposal(disposition, %{status: "expired"}) do
    %{disposition | expired_count: disposition.expired_count + 1}
  end

  defp fold_proposal(disposition, %{status: status}) when status in ["pending", "deferred"] do
    %{disposition | open: true}
  end

  defp fold_proposal(disposition, _row), do: disposition
end
