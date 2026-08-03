defmodule FermixCore.SkillCuration.Delivery do
  @moduledoc """
  Proposal delivery (MILESTONE_26_SKILL_CURATION §6.6): one deterministic
  target-resolution ladder evaluated once per cycle, an owner-privacy check on
  the resolved target, and one send per proposal through the shared
  `Delivery.ChannelSend` primitive — button-capable adapters get the
  `{:send_proposal, token}` dispatch, everyone else the same message with the
  typed commands spelled out.

  Proposals quote the owner's own private messages, so a group target
  (legitimate for jobs) is treated as unresolvable, never sent to.
  """

  require Logger

  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.Prompt.InjectionScan
  alias FermixCore.SkillCuration.Proposals

  # All owner-capable channels (for the configured-owners map + rung-1
  # owner-privacy checks).
  @owner_channel_order [:telegram, :discord, :signal, :slack, :whatsapp]
  # Derived owner-inbox rung (§6.6): only channels where the DM destination IS
  # the bare owner user id. Discord and Slack need a DM-channel derivation the
  # adapters don't have yet (design open question 2) — they participate via an
  # owner-private rung-1 jobs target only, never via a doomed derived send.
  @derived_inbox_order [:telegram, :signal, :whatsapp]
  @local_channels ["cli", "daemon"]
  # Jobs-target destination keys, in DeliveryDefaults' own precedence.
  @destination_keys ~w(chat_id channel_id recipient target reply_target)
  # At most this many verified quotes render into a proposal message (§10).
  @rendered_quotes 2

  @type target :: %{platform: String.t(), destination: String.t()}

  @doc """
  Resolve the delivery target: (1) the configured jobs
  `default_delivery_target` when owner-private, (2) the derived owner DM on
  the first owner-configured channel, (3) `:no_delivery_target`.
  """
  @spec resolve_target(keyword()) :: {:ok, target()} | :no_delivery_target
  def resolve_target(opts \\ []) do
    owners = Keyword.get_lazy(opts, :configured_owners, &configured_owners/0)

    case jobs_target(Keyword.get_lazy(opts, :jobs_config, &jobs_config/0), owners) do
      {:ok, target} -> {:ok, target}
      :skip -> derived_owner_inbox(owners)
    end
  end

  @doc """
  Deliver proposal rows to the resolved target. Deferred rows transition to
  pending on send; every delivered row gets its origin stamped for the §6.7
  same-origin action check. Returns the cycle's `delivery_status`.
  """
  @spec deliver([map()], DateTime.t(), keyword()) ::
          {:ok, :delivered | :no_delivery_target | :send_failed | :nothing_to_deliver}
  def deliver([], _now, _opts), do: {:ok, :nothing_to_deliver}

  def deliver(rows, %DateTime{} = now, opts) do
    case resolve_target(opts) do
      :no_delivery_target ->
        {:ok, :no_delivery_target}

      {:ok, target} ->
        {:ok, send_all(rows, target, now, opts)}
    end
  end

  @doc """
  Render the stored proposal text (sans action affordances): task pattern,
  evidence count, verified quotes (injection-scanned; suspect quotes are
  withheld, not rendered), and the outline.
  """
  @spec render_summary(map()) :: String.t()
  def render_summary(%{kind: "archive_skill"} = proposal) do
    """
    Skill archive proposal: #{proposal.skill_name}
    #{proposal.rationale}
    Archiving is reversible: `/skills restore #{proposal.skill_name}` brings it back.\
    """
  end

  def render_summary(proposal) do
    header =
      case proposal.kind do
        "new_skill" -> "Skill proposal: #{proposal.name} (new skill)"
        "update_skill" -> "Skill update proposal: #{proposal.name}"
      end

    evidence_count = length(proposal.evidence)

    [
      header,
      "Repeated task: #{proposal.task_signature} — asked #{evidence_count}x in the last month.",
      rendered_quotes(proposal.evidence),
      outline_line(proposal.outline),
      rationale_line(proposal.rationale)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  # -- target ladder -----------------------------------------------------

  defp jobs_target(jobs_config, owners) do
    jobs_config
    |> Keyword.get(:default_delivery_target)
    |> normalize_jobs_target()
    |> validate_owner_private(owners)
  end

  defp normalize_jobs_target(nil), do: nil

  defp normalize_jobs_target(target) when is_map(target) or is_list(target) do
    normalized =
      Map.new(target, fn {key, value} -> {to_string(key), value} end)

    platform = normalized["channel"] || normalized["platform"]
    destination = Enum.find_value(@destination_keys, &normalized[&1])

    if is_binary(platform) and is_binary(destination) do
      %{platform: platform, destination: destination}
    end
  end

  defp normalize_jobs_target(_target), do: nil

  defp validate_owner_private(nil, _owners), do: :skip

  defp validate_owner_private(%{platform: platform} = target, _owners)
       when platform in @local_channels do
    {:ok, target}
  end

  defp validate_owner_private(%{platform: platform, destination: destination} = target, owners) do
    if Map.get(owners, platform) == destination do
      {:ok, target}
    else
      :skip
    end
  end

  defp derived_owner_inbox(owners) do
    @derived_inbox_order
    |> Enum.find_value(fn channel ->
      case Map.get(owners, Atom.to_string(channel)) do
        nil -> nil
        owner_id -> %{platform: Atom.to_string(channel), destination: owner_id}
      end
    end)
    |> case do
      nil -> :no_delivery_target
      target -> {:ok, target}
    end
  end

  defp configured_owners do
    @owner_channel_order
    |> Enum.map(fn channel ->
      {Atom.to_string(channel), FermixCore.Config.channel_explicit_owner_user_id(channel)}
    end)
    |> Enum.reject(fn {_channel, owner} -> is_nil(owner) end)
    |> Map.new()
  end

  defp jobs_config, do: Application.get_env(:fermix_core, :jobs, [])

  # -- sending -----------------------------------------------------------

  defp send_all(rows, target, now, opts) do
    # Capability is probed before composing (§6.6): button-capable adapters
    # get button dispatch, all others the same text with the typed commands
    # spelled out. One primitive, capability-branched rendering.
    buttons? = proposal_buttons?(target.platform, opts)

    results = Enum.map(rows, &send_one(&1, target, buttons?, now, opts))

    if Enum.all?(results, &(&1 == :ok)), do: :delivered, else: :send_failed
  end

  defp proposal_buttons?(platform, opts) do
    case ChannelSend.resolve_adapter(platform, channel_send_opts(opts)) do
      {:ok, adapter} -> function_exported?(adapter, :send_proposal, 3)
      {:error, _reason} -> false
    end
  end

  # The cycle's `:adapter` opt is the PROVIDER seam (miner); the channel-side
  # injection travels as `:channel_adapter` and maps onto ChannelSend's
  # `:adapter` here, so the two seams can never collide.
  defp channel_send_opts(opts) do
    [adapter: Keyword.get(opts, :channel_adapter), channels: Keyword.get(opts, :channels)]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp send_one(row, target, buttons?, now, opts) do
    with :ok <- mark_deliverable(row, now, opts),
         :ok <- dispatch(row, target, buttons?, opts) do
      stamp_origin(row, target, now, opts)
    else
      {:error, reason} ->
        Logger.warning("skill_curation proposal #{row.token} delivery failed: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp mark_deliverable(%{status: "deferred", token: token}, now, opts) do
    case Proposals.deliver_deferred(token, now, repo_opt(opts)) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_deliverable(_row, _now, _opts), do: :ok

  defp dispatch(row, target, true, opts) do
    ChannelSend.send(
      target.platform,
      target.destination,
      row.summary,
      [],
      channel_send_opts(opts) ++ [dispatch: {:send_proposal, row.token}]
    )
  end

  defp dispatch(row, target, false, opts) do
    text =
      row.summary <>
        "\n\nApprove: `/skills approve #{row.token}` · Deny: `/skills deny #{row.token}`"

    ChannelSend.send(
      target.platform,
      target.destination,
      text,
      [],
      channel_send_opts(opts)
    )
  end

  defp stamp_origin(row, target, now, opts) do
    case Proposals.stamp_origin(
           row.token,
           target.platform,
           target.destination,
           now,
           repo_opt(opts)
         ) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_opt(opts), do: Keyword.take(opts, [:repo])

  # -- rendering ---------------------------------------------------------

  defp rendered_quotes(evidence) do
    evidence
    |> Enum.take(@rendered_quotes)
    |> Enum.map(&safe_quote/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Mined history is data, never instructions (§8.3): a quote tripping the
  # injection scan is withheld from the rendered message rather than shown —
  # the evidence count still carries the signal.
  defp safe_quote(%{quote: text}) when is_binary(text) and text != "" do
    case InjectionScan.scan(text) do
      {:ok, _text} -> "> \"#{text}\""
      {:suspect, _text, _matches} -> "> (quote withheld: suspicious content)"
    end
  end

  defp safe_quote(_evidence), do: nil

  defp outline_line([]), do: nil
  defp outline_line(outline), do: "Outline: " <> Enum.join(outline, "; ")

  defp rationale_line(""), do: nil
  defp rationale_line(rationale), do: "Why: #{rationale}"
end
