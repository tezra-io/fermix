defmodule FermixCore.Delivery.OwnerInbox do
  @moduledoc """
  The one answer to "where is the owner's inbox".

  Two subsystems ask it — skill-curation proposals
  (MILESTONE_26_SKILL_CURATION §6.6) and temporal reminders (MILESTONE_30 §11.1)
  — and answering it two different ways is the defect this module exists to
  prevent. The precedence, evaluated once at acceptance time and never at send
  time:

    1. the configured `[fermix_core.jobs] default_delivery_target`;
    2. the owner DM derived from the first owner-configured channel, in one
       fixed order;
    3. `:no_delivery_target`.

  Derivation reads only an **explicit** `owner_user_id`
  (`Config.channel_explicit_owner_user_id/1`): a configured channel with no
  owner identity is not an inbox, and a member of `allowed_user_ids` is never
  promoted to owner here. Channel presence alone derives nothing.

  Only channels whose DM destination *is* the bare owner user id can be derived
  (Telegram, Signal, WhatsApp). A Discord or Slack DM needs a channel-id
  derivation the adapters do not have, so a bare user id there would fail at
  send time while every gate reported OK; those channels reach the owner
  through an explicit rung-one target only.

  Every inbox this module returns is root-scoped: it answers an inbox identity,
  not a thread. A caller that must honor a configured thread field (Temporal
  §11.1 normalizes `message_thread_id`/`thread_ts`) reads the raw jobs target
  itself and uses `derived_candidates/1` for rung two, applying its own
  rung-one validation — same precedence, its own acceptance rules.

  A third question is the owner's inbox on ONE named platform (`on_platform/2`,
  M56 §4.7: "send it to my Telegram"), which never answers another platform's.
  A remote platform's inbox is the configured target when it is that
  platform's and the owner's own, else the owner DM its owner id derives. A
  transport only the owner reaches (the Mac's chat socket, the paired phones)
  has no owner id: its channel adapter names the inbox itself
  (`owner_inbox/0`), or says it cannot deliver now.
  """

  alias FermixCore.Config
  alias FermixCore.Delivery.ChannelSend

  # All owner-capable channels, in the order owner identity is read.
  @owner_channel_order [:telegram, :discord, :signal, :slack, :whatsapp]
  # The same channels as platform names: the ones whose inbox an owner id makes.
  @remote_platforms Enum.map(@owner_channel_order, &Atom.to_string/1)
  # The derived rung: channels where the DM destination IS the bare owner id.
  @derived_inbox_order ["telegram", "signal", "whatsapp"]
  # Local targets are owner-private by construction — nobody else can read them.
  @local_channels ["cli", "daemon"]
  # Jobs-target destination keys, in `Jobs.DeliveryDefaults`' own precedence.
  @destination_keys ~w(chat_id channel_id recipient target reply_target)
  @root_scope "root"

  @type inbox :: %{
          platform: String.t(),
          destination: String.t(),
          thread_scope: String.t(),
          source: :configured | :derived | :transport
        }

  @typedoc """
  Why a named platform has no owner inbox: it is no delivery channel (the
  send path's own reason, `ChannelSend.resolve_adapter/2`), or it is one with
  no inbox of the owner's on it now.
  """
  @type platform_refusal ::
          {:unsupported_delivery_platform, String.t()}
          | {:invalid_delivery_adapter, term()}
          | :no_owner_inbox

  @type owners :: %{String.t() => String.t()}

  @doc """
  Resolves the owner's inbox through the full precedence.

  Rung one is accepted only when the configured target *is* the owner's own
  inbox: a group chat is a legitimate jobs target but is not an owner inbox, so
  it falls through to derivation rather than receiving owner-private content.

  Seams: `:jobs_config` and `:configured_owners`.
  """
  @spec resolve(keyword()) :: {:ok, inbox()} | :no_delivery_target
  def resolve(opts \\ []) when is_list(opts) do
    owners = owners(opts)

    case configured_inbox(opts, owners) do
      {:ok, inbox} -> {:ok, inbox}
      :skip -> first_candidate(candidates(owners))
    end
  end

  @doc """
  The derived rung alone: every owner-configured inbox, in the fixed order.

  For callers whose rung one has its own acceptance rules (Temporal §11.1) and
  that must therefore validate each candidate themselves.
  """
  @spec derived_candidates(keyword()) :: [inbox()]
  def derived_candidates(opts \\ []) when is_list(opts), do: opts |> owners() |> candidates()

  @doc "The explicitly configured owner id of every owner-capable channel."
  @spec configured_owners() :: owners()
  def configured_owners do
    @owner_channel_order
    |> Enum.map(fn channel ->
      {Atom.to_string(channel), Config.channel_explicit_owner_user_id(channel)}
    end)
    |> Enum.reject(fn {_channel, owner} -> is_nil(owner) end)
    |> Map.new()
  end

  @doc """
  The owner's own inbox on `platform`, and on no other.

  `platform` must be a delivery channel (`[fermix_core.jobs]`'s
  `delivery_channels`); otherwise the refusal is the send path's own. A remote
  platform answers the configured target when it is on `platform` and is the
  owner's inbox, else the owner DM derived for it (Telegram, Signal,
  WhatsApp). Any other channel answers what its adapter's `owner_inbox/0`
  names, and an adapter without one (the CLI) is no inbox.

  Seams: `:jobs_config` (its `:delivery_channels` and
  `:default_delivery_target`) and `:configured_owners`.
  """
  @spec on_platform(String.t(), keyword()) :: {:ok, inbox()} | {:error, platform_refusal()}
  def on_platform(platform, opts \\ []) when is_binary(platform) and is_list(opts) do
    case ChannelSend.resolve_adapter(platform, channels: delivery_channels(opts)) do
      {:ok, adapter} -> platform_inbox(platform, adapter, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Every delivery channel with an owner inbox now (`on_platform/2`), in name
  order. Seams as `on_platform/2`.
  """
  @spec reachable_platforms(keyword()) :: [String.t()]
  def reachable_platforms(opts \\ []) when is_list(opts) do
    opts
    |> delivery_channels()
    |> Enum.map(fn {platform, _adapter} -> to_string(platform) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.filter(&match?({:ok, _inbox}, on_platform(&1, opts)))
  end

  # --- rung one: the configured target ------------------------------------

  defp configured_inbox(opts, owners) do
    opts
    |> Keyword.get_lazy(:jobs_config, &jobs_config/0)
    |> Keyword.get(:default_delivery_target)
    |> normalize_target()
    |> owner_private(owners)
  end

  defp normalize_target(nil), do: nil

  defp normalize_target(target) when is_map(target) or is_list(target) do
    normalized = Map.new(target, fn {key, value} -> {to_string(key), value} end)
    platform = normalized["channel"] || normalized["platform"]
    destination = Enum.find_value(@destination_keys, &normalized[&1])

    if is_binary(platform) and is_binary(destination) do
      inbox(platform, destination, :configured)
    end
  end

  defp normalize_target(_target), do: nil

  defp owner_private(nil, _owners), do: :skip

  defp owner_private(%{platform: platform} = inbox, _owners) when platform in @local_channels do
    {:ok, inbox}
  end

  defp owner_private(%{platform: platform, destination: destination} = inbox, owners) do
    if Map.get(owners, platform) == destination, do: {:ok, inbox}, else: :skip
  end

  # --- rung two: the derived inbox ----------------------------------------

  defp candidates(owners) do
    Enum.flat_map(@derived_inbox_order, fn platform ->
      case Map.get(owners, platform) do
        owner when is_binary(owner) and owner != "" -> [inbox(platform, owner, :derived)]
        _no_owner -> []
      end
    end)
  end

  defp first_candidate([]), do: :no_delivery_target
  defp first_candidate([inbox | _rest]), do: {:ok, inbox}

  # --- one named platform --------------------------------------------------

  defp platform_inbox(platform, _adapter, opts) when platform in @remote_platforms do
    owners = owners(opts)

    case configured_inbox(opts, owners) do
      {:ok, %{platform: ^platform} = inbox} -> {:ok, inbox}
      _other_or_none -> derived_inbox(platform, owners)
    end
  end

  defp platform_inbox(platform, adapter, _opts) do
    if function_exported?(adapter, :owner_inbox, 0),
      do: transport_inbox(platform, adapter.owner_inbox()),
      else: {:error, :no_owner_inbox}
  end

  defp derived_inbox(platform, owners) do
    case Enum.find(candidates(owners), &(&1.platform == platform)) do
      nil -> {:error, :no_owner_inbox}
      inbox -> {:ok, inbox}
    end
  end

  defp transport_inbox(platform, {:ok, destination})
       when is_binary(destination) and destination != "",
       do: {:ok, inbox(platform, destination, :transport)}

  defp transport_inbox(_platform, :unavailable), do: {:error, :no_owner_inbox}

  # --- shared --------------------------------------------------------------

  defp inbox(platform, destination, source) do
    %{
      platform: platform,
      destination: destination,
      thread_scope: @root_scope,
      source: source
    }
  end

  defp owners(opts), do: Keyword.get_lazy(opts, :configured_owners, &configured_owners/0)

  defp delivery_channels(opts) do
    opts
    |> Keyword.get_lazy(:jobs_config, &jobs_config/0)
    |> Keyword.get(:delivery_channels, %{})
  end

  defp jobs_config, do: Application.get_env(:fermix_core, :jobs, [])
end
