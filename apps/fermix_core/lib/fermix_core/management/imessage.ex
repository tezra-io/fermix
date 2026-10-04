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
  """

  alias FermixCore.Auth.Redaction
  alias FermixCore.IMessage, as: Channel
  alias FermixCore.IMessage.Control
  alias FermixCore.IMessage.HelperInstaller
  alias FermixCore.Management.Jobs

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
      with {:ok, policy} <- policy_for(config(opts)) do
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

    case reader.() do
      {:ok, policy} -> Control.policy_matches_config?(policy, config(opts))
      {:error, reason} -> log_false("policy read", reason)
    end
  end

  defp policy_matches?(_probe, _opts), do: false

  defp log_false(what, reason) do
    Logger.error("management imessage #{what} refused: #{Redaction.format(reason)}")
    false
  end

  defp config(opts),
    do:
      Keyword.get_lazy(opts, :config, fn ->
        Application.get_env(:fermix_channels, :imessage, [])
      end)

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

  # The residue. A helper reason carries its own words and the path it was
  # spawned from, so it goes to the daemon log and the sentence stays fixed.
  defp sentence(reason) do
    Logger.error("management imessage refused: #{Redaction.format(reason)}")
    "Fermix Messages could not finish. See the daemon log."
  end
end
