defmodule FermixCore.Delivery.OwnerInbox do
  @moduledoc """
  The one answer to "where is the owner's inbox".

  Many subsystems ask it (a heal's message and card, cue and soul notices,
  call reports, meeting notes, skill-curation proposals, open-loop check-ins
  said elsewhere, access confirmations with no chat of their own), and
  answering it two different ways is the defect this module exists to
  prevent. The precedence, evaluated once at acceptance time and never at
  send time (M106 §8):

    1. the configured `[fermix_core.jobs] default_delivery_target`, when it
       is the owner's own inbox;
    2. the Fermix app's inbox, while a phone is paired (D3);
    3. the owner DM derived from the first owner-configured channel, in one
       fixed order;
    4. the Fermix app's inbox when this engine has an app to show it, with no
       phone and no DM (D9);
    5. `:no_delivery_target`.

  The order is not a setting: an owner with a paired phone who wants their
  notices elsewhere names that place as the default target.

  **The app's inbox** is the Mac chat's conversation, which a paired phone
  shares (its turns join it, and a row written there is pushed to it): its
  destination is what the `companion` adapter's `owner_inbox/0` names. A row
  addressed to the phone channel itself would land in a conversation no turn
  reads, so the app's inbox is always the `companion` one, and a configured
  target naming `mobile` or `companion` at that destination is taken as it.
  "A phone is paired" is one optional question to the `mobile` adapter in
  the delivery-channels map (`phone_paired?/0`), so core never depends on
  channels code; a channel with no phone paired is no reason to put the app
  first. The app alone is the inbox, last, when this engine has an app
  (`Cues.Mandates.app_surface?/1`) or a computer of this home is linked to
  it, connected now or not (the second question, `computer_linked?/0`).

  Derivation reads only an **explicit** `owner_user_id`
  (`Config.channel_explicit_owner_user_id/1`): a configured channel with no
  owner identity is not an inbox, and a member of `allowed_user_ids` is never
  promoted to owner here. Channel presence alone derives nothing.

  Only channels whose DM destination *is* the bare owner user id can be derived
  (Telegram, Signal, WhatsApp, iMessage). A Discord or Slack DM needs a channel-id
  derivation the adapters do not have, so a bare user id there would fail at
  send time while every gate reported OK; those channels reach the owner
  through an explicit rung-one target only. `derived_candidates/1` is that
  DM rung alone: the app is never a reminder's inbox.

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
  alias FermixCore.Cues.Mandates
  alias FermixCore.Delivery.ChannelSend
  alias FermixCore.IMessage

  # The Fermix app's inbox (M106 §8): the Mac chat's conversation, which a
  # paired phone shares. An answer typed on either transport is the app's.
  @app_platform "companion"
  @phone_platform "mobile"
  @app_platforms [@app_platform, @phone_platform]
  # The user an answer typed in the app carries: the Mac chat's socket and a
  # paired phone are each authenticated by their transport, and carry no
  # user id of their own.
  @app_user "app"
  @app_place "the Fermix app"

  # All owner-capable channels, in the order owner identity is read.
  @owner_channel_order [:telegram, :discord, :signal, :slack, :whatsapp, :imessage]
  # The same channels as platform names: the ones whose inbox an owner id makes.
  @remote_platforms Enum.map(@owner_channel_order, &Atom.to_string/1)
  # The derived rung: channels where the DM destination IS the bare owner id.
  # An iMessage direct conversation is keyed by the owner's handle (M54 §7.5).
  @derived_inbox_order ["telegram", "signal", "whatsapp", "imessage"]
  # Local targets are owner-private by construction — nobody else can read them.
  @local_channels ["cli", "daemon"]
  # The user every message typed in the local `cli` chat carries
  # (`FermixChannels.CLI`): only the owner types there.
  @cli_user "cli"
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

  @typedoc "Where the owner's answer to a prompt sent to their DM comes from."
  @type dm_origin :: %{platform: String.t(), chat_id: String.t(), user_id: String.t()}

  @typedoc """
  What an ask waits on, and so what the place it goes must draw
  (`for_approval/2`): an approval card, which every Fermix app draws and
  answers (a heal's proposal, an access confirmation), or a watcher's
  proposal card, which the phone's wire does not carry and which reaches the
  apps through their own proposal surface, so it goes to a chat or nowhere.
  """
  @type ask :: :approval_card | :proposal_card

  @doc """
  The one owner of the rule "a DM's chat id is the owner's user id": on
  Telegram, Signal, WhatsApp and iMessage the owner's DM `inbox` is keyed by the
  owner's own id, so an answer to a prompt sent there (`/confirm`) can be held
  to that chat and that user. Answers that origin, or `:error` for any other
  inbox, which then cannot carry such a confirmation.
  """
  @spec dm_origin(%{
          required(:platform) => String.t(),
          required(:destination) => String.t(),
          optional(atom()) => term()
        }) :: {:ok, dm_origin()} | :error
  def dm_origin(%{platform: platform, destination: owner})
      when platform in @derived_inbox_order and is_binary(owner) and owner != "",
      do: {:ok, %{platform: platform, chat_id: owner, user_id: owner}}

  def dm_origin(%{platform: platform, destination: destination})
      when is_binary(platform) and is_binary(destination),
      do: :error

  @doc """
  Where an answer to a card sent to the owner's `inbox` comes from, so the
  card can be held to that chat and that user (a heal's proposal, M106 §5.7):
  a DM's origin (`dm_origin/1`); the local `cli` chat's, which rung one
  already takes as the owner's own because only the owner types there (its
  chat is the inbox's destination, its user the one every message typed
  there carries); or, for the Fermix app's inbox, the app's origin
  (`app_origin/1`), which an answer typed on the Mac chat or on a paired
  phone carries (`answered_in_app/2`). `:error` for any other inbox. Who
  uses `dm_origin/1` for their reach (a watcher's card) is untouched by this.
  """
  @spec answer_origin(%{
          required(:platform) => String.t(),
          required(:destination) => String.t(),
          optional(atom()) => term()
        }) :: {:ok, dm_origin()} | :error
  def answer_origin(%{platform: "cli", destination: chat}) when is_binary(chat) and chat != "",
    do: {:ok, %{platform: "cli", chat_id: chat, user_id: @cli_user}}

  def answer_origin(%{platform: @app_platform, destination: chat})
      when is_binary(chat) and chat != "",
      do: {:ok, app_origin(chat)}

  def answer_origin(inbox), do: dm_origin(inbox)

  @doc """
  The origin of an answer typed in the Fermix app's chat `chat_id` (M106
  §8, D12): the Mac chat and a paired phone share that one conversation, so
  an answer typed on either transport is the owner's, from this one origin.
  Each transport authenticates itself (the Mac chat's owner-only socket, a
  paired phone's key), and neither carries a user id, so the origin's user
  is a fixed one only this rule gives.
  """
  @spec app_origin(String.t()) :: dm_origin()
  def app_origin(chat_id) when is_binary(chat_id) and chat_id != "",
    do: %{platform: @app_platform, chat_id: chat_id, user_id: @app_user}

  @doc """
  The one rule for an answer typed in the Fermix app: a message on the Mac
  chat (`companion`) or a paired phone (`mobile`) in chat `chat_id` answers as
  the app's origin (`app_origin/1`); a message anywhere else answers as its
  own chat (`:error`). Every answer the app may give (a card's `/confirm`,
  an access confirmation, a skill proposal's `/skills approve`) is checked
  through this rule, never a rule of its own.
  """
  @spec answered_in_app(String.t(), String.t()) :: {:ok, dm_origin()} | :error
  def answered_in_app(platform, chat_id)
      when platform in @app_platforms and is_binary(chat_id) and chat_id != "",
      do: {:ok, app_origin(chat_id)}

  def answered_in_app(platform, chat_id) when is_binary(platform) and is_binary(chat_id),
    do: :error

  @doc "Whether `inbox` is the Fermix app's inbox (the Mac chat's conversation)."
  @spec app?(%{required(:platform) => String.t(), optional(atom()) => term()}) :: boolean()
  def app?(%{platform: platform}) when is_binary(platform), do: platform == @app_platform

  @doc """
  The conversation a message sent to `inbox` is kept in, where the owner's
  next turn there reads it (M106 §5.8): an inbox keyed as a turn is, a DM
  whose chat is the owner's own id (`dm_origin/1`) or the Fermix app's
  conversation (the Mac chat's, which a phone's turns join). `:error`
  anywhere else (a Slack or Discord DM, the terminal), where a row would land
  in a conversation no turn reads.
  """
  @spec history_conversation(%{
          required(:platform) => String.t(),
          required(:destination) => String.t(),
          optional(atom()) => term()
        }) :: {:ok, {String.t(), String.t(), :root}} | :error
  def history_conversation(%{platform: platform, destination: destination} = inbox) do
    cond do
      app?(inbox) and is_binary(destination) and destination != "" ->
        {:ok, {platform, destination, :root}}

      match?({:ok, _origin}, dm_origin(inbox)) ->
        {:ok, {platform, destination, :root}}

      true ->
        :error
    end
  end

  @doc """
  How a display names where `inbox` is: "the Fermix app" for the app's
  inbox, never its internal word; every other inbox by its platform's own
  word, as each display has always printed it.
  """
  @spec place(%{required(:platform) => String.t(), optional(atom()) => term()}) :: String.t()
  def place(%{platform: platform} = inbox) when is_binary(platform),
    do: if(app?(inbox), do: @app_place, else: platform)

  @doc """
  Resolves the owner's inbox through the full precedence (moduledoc).

  Rung one is accepted only when the configured target *is* the owner's own
  inbox: a group chat is a legitimate jobs target but is not an owner inbox, so
  it falls through to derivation rather than receiving owner-private content.

  Seams: `:jobs_config` (its `:delivery_channels`, where the app's two
  adapters are asked, and `:default_delivery_target`), `:configured_owners`,
  and `:app_surface?` (else `Cues.Mandates.app_surface?/1`); whether a
  computer is linked is the `mobile` adapter's answer.
  """
  @spec resolve(keyword()) :: {:ok, inbox()} | :no_delivery_target
  def resolve(opts \\ []) when is_list(opts) do
    owners = owners(opts)

    case configured_inbox(opts, owners, true) do
      {:ok, inbox} -> {:ok, inbox}
      :skip -> opts |> paired_app() |> Kernel.++(candidates(owners)) |> or_app_alone(opts)
    end
  end

  # D9: the app's inbox is the last rung, asked only when every other is empty.
  defp or_app_alone([], opts), do: first_candidate(app_alone(opts))
  defp or_app_alone(inboxes, _opts), do: first_candidate(inboxes)

  @doc """
  The owner's inbox for a prompt that waits on the owner's answer, by what
  the prompt is (`t:ask/0`).

  `:approval_card` (a heal's proposal, an access confirmation): `resolve/1`'s
  precedence, the app first while a phone is paired and last when it is the
  only inbox, except that iMessage carried by a computer (M97 §6.4, §14)
  comes after every inbox that lives on this engine, configured or derived,
  and is never chosen while that computer is asleep or offline, nor while no
  computer or more than one carries it: a sleeping Mac is no inbox for a
  prompt that waits. iMessage on this Mac keeps its place.

  `:proposal_card` (a watcher's mandate proposal or follow-up card): the same
  with no app rung and no app target, so a paired phone changes nothing for
  it. Its reach rule (`Cues.Proposals.owner_chat/1`) offers it to the apps on
  their own proposal surface.

  Seams as `resolve/1`, and `:imessage_carrier` (`FermixCore.IMessage.carrier/1`'s
  answer), read only when an iMessage inbox is among the candidates.
  """
  @spec for_approval(ask(), keyword()) :: {:ok, inbox()} | :no_delivery_target
  def for_approval(ask, opts \\ [])

  def for_approval(:approval_card, opts) when is_list(opts) do
    owners = owners(opts)

    (configured_list(opts, owners, true) ++ paired_app(opts) ++ candidates(owners))
    |> asked_order(opts)
    |> or_app_alone(opts)
  end

  def for_approval(:proposal_card, opts) when is_list(opts) do
    owners = owners(opts)

    opts
    |> configured_list(owners, false)
    |> Kernel.++(candidates(owners))
    |> asked_order(opts)
    |> first_candidate()
  end

  defp configured_list(opts, owners, app?) do
    case configured_inbox(opts, owners, app?) do
      {:ok, inbox} -> [inbox]
      :skip -> []
    end
  end

  # The iMessage rule for a prompt that waits (the doc above).
  defp asked_order(inboxes, opts) do
    inboxes = Enum.uniq(inboxes)

    reach =
      if Enum.any?(inboxes, &(&1.platform == "imessage")), do: imessage_reach(opts), else: :here

    inboxes
    |> Enum.reject(&(&1.platform == "imessage" and reach == :unreachable))
    |> Enum.sort_by(&(&1.platform == "imessage" and reach == :carried))
  end

  defp imessage_reach(opts) do
    case Keyword.get_lazy(opts, :imessage_carrier, &IMessage.carrier/0) do
      :here -> :here
      {:computer, %{connected: true}} -> :carried
      _away_conflicting_or_none -> :unreachable
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

  # `app?` says whether a target naming the Fermix app is the owner's own here:
  # it is wherever the app is a place this ask can go, and never for a
  # watcher's proposal card or a named remote platform.
  defp configured_inbox(opts, owners, app?) do
    opts
    |> Keyword.get_lazy(:jobs_config, &jobs_config/0)
    |> Keyword.get(:default_delivery_target)
    |> normalize_target()
    |> owner_private(owners, app?, opts)
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

  defp owner_private(nil, _owners, _app?, _opts), do: :skip

  defp owner_private(%{platform: platform} = inbox, _owners, _app?, _opts)
       when platform in @local_channels do
    {:ok, inbox}
  end

  # A target naming the phone or the Mac chat is the owner's own by
  # construction, as the CLI is, when it names the app's inbox: it is taken
  # as that inbox, the Mac chat's conversation, where the phone's turns run.
  defp owner_private(%{platform: platform, destination: destination}, _owners, app?, opts)
       when platform in @app_platforms do
    case {app?, app_inbox(opts)} do
      {true, [%{destination: ^destination} = app]} -> {:ok, %{app | source: :configured}}
      _not_here_or_another_chat -> :skip
    end
  end

  defp owner_private(
         %{platform: platform, destination: destination} = inbox,
         owners,
         _app?,
         _opts
       ) do
    if Map.get(owners, platform) == destination, do: {:ok, inbox}, else: :skip
  end

  # --- the Fermix app's inbox (M106 §8) -------------------------------------

  # D3: first while a phone is paired, not merely while the phones' channel
  # runs: a channel with no phone is a row nobody reads.
  defp paired_app(opts) do
    if phone_paired?(opts), do: app_inbox(opts), else: []
  end

  # D9: the Mac chat alone, last, when the owner has a Mac to read it in:
  # this engine is an app's, or a computer of this home is linked to it. That
  # is wider than the question a watcher card's reach asks
  # (`Cues.Mandates.app_surface?/1` alone, since the apps show those cards on
  # their own proposal surface): an Always On server is no app's engine, yet
  # the owner's Mac reaches its chat through the computer's link, and a row
  # written while that Mac is away waits there for its next connection.
  defp app_alone(opts) do
    if app_surface?(opts) or computer_linked?(opts), do: app_inbox(opts), else: []
  end

  # The Mac chat's conversation, as the `companion` adapter names it; none
  # when that adapter is no delivery channel here or names no inbox.
  defp app_inbox(opts) do
    with {:ok, adapter} <-
           ChannelSend.resolve_adapter(@app_platform, channels: delivery_channels(opts)),
         true <- function_exported?(adapter, :owner_inbox, 0),
         {:ok, destination} when is_binary(destination) and destination != "" <-
           adapter.owner_inbox() do
      [inbox(@app_platform, destination, :derived)]
    else
      _no_app_inbox -> []
    end
  end

  defp phone_paired?(opts), do: phones_channel_says?(opts, :phone_paired?)

  defp computer_linked?(opts), do: phones_channel_says?(opts, :computer_linked?)

  # Asked of the `mobile` adapter in the delivery-channels map; an adapter
  # that does not answer the question has no phone or computer to count.
  defp phones_channel_says?(opts, question) do
    case ChannelSend.resolve_adapter(@phone_platform, channels: delivery_channels(opts)) do
      {:ok, adapter} -> function_exported?(adapter, question, 0) and answer!(adapter, question)
      {:error, _not_a_delivery_channel} -> false
    end
  end

  defp answer!(adapter, question) do
    case apply(adapter, question, []) do
      answer when is_boolean(answer) -> answer
    end
  end

  defp app_surface?(opts),
    do: Mandates.app_surface?(Keyword.take(opts, [:app_surface?, :host_facts]))

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

    case configured_inbox(opts, owners, false) do
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
