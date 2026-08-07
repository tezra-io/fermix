defmodule FermixChannels.Gateway.Message do
  @moduledoc """
  Normalized inbound message from any channel.

  Every channel adapter parses platform-specific payloads into this struct,
  giving the agent a uniform interface regardless of source.

  `thread_scope` is a root/thread presence marker derived from `thread_ts`.
  The actual platform thread identifier lives in `thread_ts`, and that value is
  what the shared runtime uses for thread-aware conversation identity.
  """

  @enforce_keys [:id, :content, :sender, :channel, :chat_id, :reply_target]
  defstruct [
    :id,
    :content,
    :sender,
    :channel,
    :chat_id,
    :reply_target,
    :thread_ts,
    # Filesystem working directory of the request's origin, set ONLY by the
    # local CLI bridge (never populated from remote channel user input). A
    # trusted operator turn threads it into the sandbox's standard-mode roots so
    # the agent can work where the owner ran the command.
    :request_cwd,
    # Environment overlay for the client session this request arrived on, set
    # ONLY by the local ACP transport (never populated from remote channel user
    # input), already filtered to the daemon's allowlist. A trusted operator turn
    # merges it over the sandbox's shell-command env so the agent can run the
    # client's own CLI with the credentials and PATH it was spawned with
    # (MILESTONE_29_ACP_AGENT_SURFACE.md §8.3).
    :session_env,
    thread_scope: :root,
    metadata: %{},
    attachments: [],
    # Transient materialized inbound content parts (e.g. image bytes resolved at
    # the gateway media-ingest step). NOT persisted — turn-local (M14).
    media_parts: []
  ]

  @type thread_scope :: :root | :thread
  @type thread_id :: String.t() | integer()

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          sender: String.t(),
          channel: String.t(),
          chat_id: String.t(),
          reply_target: String.t(),
          thread_ts: thread_id() | nil,
          request_cwd: String.t() | nil,
          session_env: %{String.t() => String.t()} | nil,
          thread_scope: thread_scope(),
          metadata: map(),
          attachments: [map()],
          media_parts: [map()]
        }

  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    attrs
    |> Map.put(:thread_scope, thread_scope(attrs))
    |> then(&struct!(__MODULE__, &1))
  end

  @doc """
  Whether the message carries something the agent can act on: non-blank text, or
  any materialized media. A captionless image is actionable (the media carries
  the turn); a sticker / poll / blank text with no media is not. This is the one
  shared definition of "empty inbound" the gateway guards on — replying and not
  scheduling a turn when a message is not actionable.
  """
  @spec actionable?(t()) :: boolean()
  def actionable?(%__MODULE__{content: content, media_parts: parts})
      when is_binary(content) and is_list(parts) do
    String.trim(content) != "" or parts != []
  end

  defp thread_scope(%{thread_ts: nil}), do: :root
  defp thread_scope(%{thread_ts: _thread_ts}), do: :thread
  defp thread_scope(_attrs), do: :root
end
