defmodule FermixCore.Management.IMessage do
  @moduledoc """
  `imessage.permissions.get`, `imessage.grant.start` and
  `imessage.policy.confirm` (M54 §10.2, §12).

  The read never prompts: it is the helper's non-prompting probe plus, when the
  probe says a policy is confirmed, the stored policy compared with the saved
  section. The two acts are jobs, because each waits on a person: the
  Automation prompt (or the Full Disk Access pane) for a grant, the helper's
  own recipient dialog for a confirmation. Each finishes with the same view the
  read answers, so a pane redraws from the job's result.

  A confirmation the owner cancels is how the job ends (`outcome:
  "policy_refused"`), never how it fails: Cancel is a decision, not a fault.
  The request names the owner and the recipients only: the helper derives the
  account posture as it confirms them, and refuses an owner that is the
  address Messages on this Mac is signed in as (`owner_is_this_mac`) until the
  own-account mode is supported.

  Off a Mac the channel does not exist, so every method is unavailable there.

  **The recipients are the home's** (M97 §4). On a computer linked to its
  server they are the server's, asked through the link (`settings.get
  channels.imessage`) when a confirmation or a read compares them, so this
  Mac confirms what its server holds; the confirmation itself stays here, on
  this Mac's screen, and a server can never ask for one. A server that does
  not answer refuses the confirmation with a sentence of its own.
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.Home.Link
  alias FermixCore.IMessage, as: Channel
  alias FermixCore.IMessage.Control
  alias FermixCore.IMessage.HelperInstaller
  alias FermixCore.Management.Jobs
  alias FermixCore.Management.Placement
  alias FermixCore.Management.Protocol

  require Logger

  @services %{"automation" => :automation, "full_disk_access" => :full_disk_access}
  @service_refusal "The service is `automation` or `full_disk_access`."
  @view_keys ~w(installed helper_version full_disk_access db automation messages_running
                signed_in user_session policy policy_matches_config probed_at)

  @type error ::
          {:unavailable, String.t()}
          | {:busy, String.t()}
          | {:invalid_params, String.t(), String.t()}

  @doc "The current, non-prompting permission and recipient state."
  @spec permissions(keyword()) :: {:ok, map()} | {:error, error()}
  def permissions(opts \\ []) when is_list(opts) do
    installed? = Keyword.get(opts, :installed?, &HelperInstaller.installed?/0)

    cond do
      not macos?(opts) -> {:error, {:unavailable, "imessage"}}
      not installed?.() -> {:ok, not_installed_view()}
      true -> probed_view(opts)
    end
  end

  @doc "Asks for one grant: `automation` or `full_disk_access`."
  @spec grant_start(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def grant_start(service, opts \\ []) when is_binary(service) and is_list(opts) do
    case {macos?(opts), Map.fetch(@services, service)} do
      {false, _service} -> {:error, {:unavailable, "imessage"}}
      {true, {:ok, atom}} -> start(:imessage_grant, grant_run(atom, opts), opts)
      {true, :error} -> {:error, {:invalid_params, "service", @service_refusal}}
    end
  end

  @doc """
  Asks the helper to confirm the saved recipients. The helper shows its own
  dialog naming every handle when they differ from the ones it holds.
  """
  @spec policy_confirm(keyword()) :: {:ok, map()} | {:error, error()}
  def policy_confirm(opts \\ []) when is_list(opts) do
    if macos?(opts),
      do: start(:imessage_policy_confirm, confirm_run(opts), opts),
      else: {:error, {:unavailable, "imessage"}}
  end

  defp start(kind, run, opts) do
    started =
      Jobs.start(kind, Keyword.merge(Keyword.get(opts, :jobs, []), name: "imessage", run: run))

    case started do
      {:ok, view} -> {:ok, view}
      {:error, :busy} -> {:error, {:busy, Atom.to_string(kind)}}
    end
  end

  defp grant_run(service, opts) do
    grant = Keyword.get(opts, :grant, &Control.grant/1)

    fn _job_id, _report ->
      case grant.(service) do
        {:ok, probe} -> {:ok, view(probe, opts)}
        {:error, reason} -> {:error, {:unavailable, sentence(reason)}}
      end
    end
  end

  defp confirm_run(opts) do
    set = Keyword.get(opts, :policy_set, &Control.policy_set/1)

    fn _job_id, _report ->
      with {:ok, config} <- config(opts),
           {:ok, policy} <- policy_for(config) do
        confirmed(set.(policy), opts)
      end
    end
  end

  defp policy_for(config) do
    case Control.policy_for_config(config) do
      {:ok, policy} -> {:ok, policy}
      {:error, missing} -> {:error, {:refused, sentence(missing)}}
    end
  end

  defp confirmed({:ok, _confirmation}, opts), do: outcome("confirmed", opts)

  defp confirmed({:error, {:helper_error, :policy_refused, _message}}, opts),
    do: outcome("policy_refused", opts)

  defp confirmed({:error, {:helper_error, :owner_not_self, _message}}, _opts),
    do: {:error, {:refused, sentence(:owner_not_self)}}

  defp confirmed({:error, {:helper_error, :owner_is_this_mac, _message}}, _opts),
    do: {:error, {:refused, sentence(:owner_is_this_mac)}}

  defp confirmed({:error, reason}, _opts), do: {:error, {:unavailable, sentence(reason)}}

  # Either way the job ends, the pane redraws from the probe it finishes with.
  defp outcome(word, opts) do
    case probe(opts) do
      {:ok, probe} -> {:ok, Map.put(view(probe, opts), "outcome", word)}
      {:error, reason} -> {:error, {:unavailable, sentence(reason)}}
    end
  end

  defp probed_view(opts) do
    case probe(opts) do
      {:ok, probe} ->
        {:ok, view(probe, opts)}

      {:error, reason} ->
        Logger.error("management imessage probe refused: #{Redaction.format(reason)}")
        {:error, {:unavailable, "imessage_permissions"}}
    end
  end

  defp probe(opts), do: Keyword.get(opts, :probe, fn -> Control.probe() end).()

  defp view(probe, opts) do
    %{
      "installed" => true,
      "helper_version" => probe.helper_version,
      "full_disk_access" => Atom.to_string(probe.full_disk_access),
      "db" => Atom.to_string(probe.db),
      "automation" => Atom.to_string(probe.automation),
      "messages_running" => probe.messages_running,
      "signed_in" => signed_in(probe.signed_in),
      "user_session" => probe.user_session,
      "policy" => Atom.to_string(probe.policy),
      "policy_matches_config" => policy_matches?(probe, opts),
      "probed_at" => now()
    }
  end

  defp not_installed_view do
    @view_keys |> Map.new(&{&1, nil}) |> Map.put("installed", false)
  end

  # Unknown (Automation not granted, so the helper cannot ask Messages) is the
  # absent rendering, not a third boolean.
  defp signed_in(value) when is_boolean(value), do: value
  defp signed_in(:unknown), do: nil

  # Only a confirmed policy is read: absent or unconfirmed already means
  # "Awaiting confirmation" (§10.1).
  defp policy_matches?(%{policy: :confirmed}, opts) do
    reader = Keyword.get(opts, :policy, fn -> Control.policy_get() end)

    with {:ok, policy} <- reader.(),
         {:ok, config} <- config(opts) do
      Control.policy_matches_config?(policy, config)
    else
      {:error, {:unavailable, _sentence}} -> false
      {:error, reason} -> log_false("policy read", reason)
    end
  end

  defp policy_matches?(_probe, _opts), do: false

  defp log_false(what, reason) do
    Logger.error("management imessage #{what} refused: #{Redaction.format(reason)}")
    false
  end

  # The home's owner and guests: this engine's own, or on a linked computer
  # its server's (the moduledoc).
  defp config(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} -> {:ok, config}
      :error -> home_config(Keyword.get_lazy(opts, :forwarding, &Link.forwarding/0))
    end
  end

  defp home_config(primary_forward: forward) do
    request = %{
      request_id: "imessage-recipients",
      protocol_version: Protocol.protocol_version(),
      method: "settings.get",
      params: %{"section" => "channels.imessage"}
    }

    case forward.(request, deadline_ms: Placement.forward_deadline_ms("settings.get")) do
      {:ok, %{"rows" => rows}} when is_list(rows) ->
        {:ok, recipients(rows)}

      other ->
        Logger.warning(
          "the server did not give iMessage's recipients: #{Redaction.format(other)}"
        )

        {:error, {:unavailable, sentence(:server_unreachable)}}
    end
  end

  defp home_config([]), do: {:ok, Application.get_env(:fermix_channels, :imessage, [])}

  # The section's rows as the config it was read from; a value that is no
  # handle is left out, so it can never be confirmed.
  defp recipients(rows) do
    values = Map.new(rows, fn row -> {row["key"], row["value"]} end)
    owner = handle(values["imessage_owner_user_id"])
    guests = values |> Map.get("imessage_allowed_sender_ids") |> List.wrap()

    [allowed_sender_ids: Enum.flat_map(guests, &List.wrap(handle(&1)))]
    |> then(&if(owner, do: [{:owner_user_id, owner} | &1], else: &1))
  end

  defp handle(value) do
    case Channel.normalize_handle(value) do
      {:ok, handle} -> handle
      {:error, :invalid_handle} -> nil
    end
  end

  defp macos?(opts), do: Keyword.get_lazy(opts, :macos?, &Channel.macos?/0)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp sentence(:not_installed),
    do: "Fermix Messages is not installed yet. Turn iMessage on to install it."

  defp sentence(:owner_missing),
    do: "Add your Apple ID or phone number for iMessage, then confirm."

  defp sentence(:owner_not_self),
    do: "That is not a handle of the Messages account on this Mac."

  defp sentence(:owner_is_this_mac),
    do:
      "Messages on this Mac is signed in as this address. Sign Messages in with a " <>
        "separate Apple ID for Fermix, then confirm again."

  defp sentence(:timeout), do: "Nobody answered in time. Try again when you are at the Mac."

  defp sentence(:server_unreachable),
    do:
      "Your server did not answer with who Fermix may message. Try again when it is " <>
        "reachable."

  # The residue. A helper reason carries its own words and the path it was
  # spawned from, so it goes to the daemon log and the sentence stays fixed.
  defp sentence(reason) do
    Logger.error("management imessage refused: #{Redaction.format(reason)}")
    "Fermix Messages could not finish. See the daemon log."
  end
end
