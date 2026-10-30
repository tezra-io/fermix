defmodule FermixCore.Browser.Scope do
  @moduledoc """
  Whose browser a tool call runs in.

  The key `owner_key/1` returns names everything the browser keeps for one
  scope: its live `ProfileServer` (`ProfileManager` registers it as
  `{key, profile_name}`), its Chrome user-data directory (`profile_dir/2`,
  `<home>/browser/profiles/<key>/<profile_name>`), and its screenshots and
  downloads under `<home>/browser/artifacts/<key>` and
  `<home>/browser/downloads/<key>`.

  The key follows the trust the call runs at, read by
  `Capabilities.Registry.run_trust/1` (the person's `source_trust` met with the
  trust the run's loop stamped), which is how the job tools, skills and
  sub-agents read it too:

    * `:operator` is the owner, keyed `"owner"`: one profile per device (this
      Fermix home), shared by every conversation the owner runs here, chats on
      any channel, scheduled jobs, cue runs and delegated workers alike. A site
      signed in once stays signed in for all of them.
    * `:guest` is keyed `"guest-"` and the unpadded url-safe Base64 of SHA-256
      over the conversation key (`guest_key/1`): one profile per conversation,
      so a guest shares cookies with neither the owner nor another
      conversation. A run below the owner's trust in the owner's conversation,
      such as a plugin skill, is a guest there.
    * No trust at all is refused (`missing_trust`), never resolved: a call path
      that forgot its trust must not put a guest in the owner's profile.

  Inside a profile, the tabs a call acts on by default are its conversation's
  (`tab_affinity/1`): the profile, its sign-ins and its one Chrome are shared,
  and which tab is "the current one" is not.

  The Fermix app's browser pane is the exception to sharing. A pane task is
  bound to the turn that started it and ends with it (`HostServer`), so each
  conversation's pane work runs in a profile of its own (`pane_key/2`):
  `"owner-"` and its conversation key's digest for the owner, and for a guest
  the guest key it already has. `Routing` decides which of the two keys serves
  a request.

  The keys cannot name each other's directories: `"owner"` is 5 characters,
  and every guest key and owner pane key 49, under different prefixes. A
  profile kept before this scheme is a directory named by the bare
  43-character digest of its conversation key. Nothing reads one:
  there is no adoption and no migration, so the owner signs in once more in the
  shared profile, a guest conversation starts signed out once, and the old
  directories stay on disk untouched until someone deletes them.
  """

  alias FermixCore.Browser.Error
  alias FermixCore.Capabilities.Registry, as: CapabilityRegistry
  alias FermixCore.Setup.ConfigStore

  @owner_key "owner"
  @guest_prefix "guest-"
  @owner_pane_prefix "owner-"

  @typedoc """
  A conversation key: a chat's `ConversationKey.t()`, or a job run's
  `{:scheduled_job, job_id, run_id}`.
  """
  @type conversation_key :: {term(), term(), term()}

  @doc """
  The scope key of a tool call: `"owner"` at operator trust, the conversation's
  `guest_key/1` at guest trust, and `missing_trust` when the context carries
  neither.
  """
  @spec owner_key(map()) :: {:ok, String.t()} | {:error, Error.t()}
  def owner_key(context) when is_map(context) do
    case CapabilityRegistry.run_trust(context) do
      :operator -> {:ok, @owner_key}
      :guest -> guest_scope(context)
      _no_trust -> {:error, missing_trust()}
    end
  end

  @doc "The key of a guest's profile in `conversation_key`, the same on every call."
  @spec guest_key(conversation_key()) :: String.t()
  def guest_key(conversation_key)
      when is_tuple(conversation_key) and tuple_size(conversation_key) == 3,
      do: @guest_prefix <> digest(conversation_key)

  @doc """
  The key of `conversation_key`'s own profile in the Fermix app's browser pane,
  given the call's scope key (`owner_key/1`). A pane task belongs to the turn
  that started it and ends with it (`HostServer`), so the pane is never shared:
  the owner's pane profiles are one per conversation, keyed `"owner-"` and the
  conversation key's digest, while a guest's is its conversation's guest key,
  the one its Chrome profile already has.
  """
  @spec pane_key(String.t(), conversation_key()) :: String.t()
  def pane_key(@owner_key, conversation_key)
      when is_tuple(conversation_key) and tuple_size(conversation_key) == 3,
      do: @owner_pane_prefix <> digest(conversation_key)

  def pane_key(@guest_prefix <> _digest = guest_key, conversation_key)
      when is_tuple(conversation_key) and tuple_size(conversation_key) == 3,
      do: guest_key

  @doc """
  The conversation a call's tabs belong to inside its profile: its
  conversation key. One owner profile serves every owner conversation, so a
  call that names no `target` acts on its own conversation's current tab
  (`CDP.Backend`), never on the tab another conversation opened last. A chat,
  each scheduled job run and each cue run is a conversation of its own; a
  delegated worker carries its parent's key and works in its parent's tab.
  """
  @spec tab_affinity(map()) :: {:ok, conversation_key()} | {:error, Error.t()}
  def tab_affinity(%{conversation_key: {_first, _second, _third} = conversation_key}),
    do: {:ok, conversation_key}

  def tab_affinity(context) when is_map(context) do
    {:error,
     Error.new(
       "missing_conversation_key",
       "browser requires conversation_key in the tool context"
     )}
  end

  @doc "The Chrome user-data directory of `profile_name` in the scope `key`."
  @spec profile_dir(String.t(), String.t()) :: String.t()
  def profile_dir(key, profile_name)
      when is_binary(key) and key != "" and is_binary(profile_name) and profile_name != "" do
    Path.join([ConfigStore.workspace_paths().browser, "profiles", key, profile_name])
  end

  defp digest(conversation_key) do
    conversation_key
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp guest_scope(context) do
    with {:ok, conversation_key} <- tab_affinity(context) do
      {:ok, guest_key(conversation_key)}
    end
  end

  defp missing_trust do
    Error.new(
      "missing_trust",
      "browser requires the call's trust (owner or guest) in the tool context, " <>
        "to choose between the owner's profile and the conversation's own"
    )
  end
end
