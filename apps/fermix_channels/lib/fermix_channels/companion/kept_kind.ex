defmodule FermixChannels.Companion.KeptKind do
  @moduledoc """
  What one kind of thing Fermix keeps is on a companion connection (M89 §07):
  the store calls a connection makes for it, its events and their shapes, and
  the messages its window and its draws ride. `Companion.Connection` pulls,
  edits, holds and pushes every kind the same way (`Companion.Kept`); a kind's
  module answers only what is its own. The owner's lists are
  `Companion.Checklists`.
  """

  @typedoc "What a device's edit did: the thing it changed, what it made, and whether it was sent before."
  @type edited :: %{id: String.t(), made: String.t() | nil, duplicate: boolean()}

  @doc "The index a device draws, read for the connection's `caller`."
  @callback index(caller :: atom() | nil, opts :: keyword()) :: {:ok, [map()]} | {:error, term()}

  @doc "One thing by its id, its removed rows too when `removed?`."
  @callback object(id :: String.t(), removed? :: boolean(), caller :: atom() | nil, keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "One edit a device sent, applied once by its `client_msg_id`."
  @callback edit(payload :: map(), caller :: atom() | nil, opts :: keyword()) ::
              {:ok, edited()} | {:error, term()}

  @doc "The sentence a refused pull or edit is answered with."
  @callback describe_error(reason :: term()) :: String.t()

  @doc "Whether a push's read failed because the thing is gone for good, so it is let go."
  @callback gone?(reason :: term()) :: boolean()

  @doc "The event the index is sent as."
  @callback index_event() :: String.t()

  @doc "The event one thing is sent as."
  @callback object_event() :: String.t()

  @doc "The field of a pull that names the thing."
  @callback id_field() :: String.t()

  @doc "The index event's payload."
  @callback index_payload(profile_id :: String.t(), entries :: [map()]) :: map()

  @doc "One thing's event payload: its removed rows when `removed?`, and `made` when not empty."
  @callback object_payload(String.t(), snapshot :: map(), removed? :: boolean(), made :: map()) ::
              map()

  @doc "The message that ends the connection's window for the kind."
  @callback flush_message() :: atom()

  @doc "The kept kind `FermixCore.ReplyBlocks.drawn_types/3` names once its index is pulled."
  @callback drawn_kind() :: FermixCore.ReplyBlocks.kept_kind()

  @doc "The type of the block under a reply that names the kind's things."
  @callback block_type() :: String.t()

  @doc "The key a queued request carries saying whether its connection draws the kind."
  @callback draws_key() :: atom()

  @doc "The message the session a phone's channel serves is told once it draws the kind."
  @callback draws_message() :: atom()
end
