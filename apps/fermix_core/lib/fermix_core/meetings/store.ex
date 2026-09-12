defmodule FermixCore.Meetings.Store do
  @moduledoc """
  Meetings persistence — a thin client over the durable `Memory.Repo` calls.

  The row is the record of a meeting: the Session writes its status on every
  transition, so a crashed or restarted daemon leaves a row that says exactly
  how far the meeting got. Nothing here caches; every read goes to the Repo.

  Every function takes an optional `opts` keyword forwarded to the Repo
  (`server:` selects a Repo instance) — the seam the temporal registry uses.
  """

  alias FermixCore.Memory.Repo
  alias FermixCore.Memory.Repo.MeetingsSql

  @type meeting :: %{
          id: String.t(),
          platform: String.t(),
          url: String.t(),
          title: String.t() | nil,
          status: String.t(),
          requested_by: String.t(),
          origin_session_id: String.t() | nil,
          started_at: String.t() | nil,
          ended_at: String.t() | nil,
          artifact_dir: String.t() | nil,
          error: String.t() | nil,
          created_at: String.t()
        }

  @doc """
  Inserts a requested meeting.

  `attrs`: `%{id, platform, url, title, requested_by, origin_session_id,
  created_at}`. The status is always `requested` — a meeting is never inserted
  mid-flight.
  """
  @spec insert(map(), keyword()) :: {:ok, meeting()} | {:error, term()}
  def insert(attrs, opts \\ []) when is_map(attrs) do
    Repo.create_meeting(attrs, opts)
  end

  @doc "Writes one state transition, with the side fields that transition owns."
  @spec update_status(String.t(), String.t(), map(), keyword()) ::
          {:ok, meeting()} | {:error, :not_found | term()}
  def update_status(id, status, fields \\ %{}, opts \\ [])
      when is_binary(id) and is_binary(status) and is_map(fields) do
    Repo.update_meeting_status(id, status, fields, opts)
  end

  @spec get(String.t(), keyword()) :: {:ok, meeting()} | {:error, :not_found | term()}
  def get(id, opts \\ []) when is_binary(id) do
    Repo.get_meeting(id, opts)
  end

  @doc """
  Lists meetings newest first.

  `filter`: `scope: :active | :recent` (default `:recent`) and `limit`
  (default 20, clamped to 50).
  """
  @spec list(map(), keyword()) :: {:ok, [meeting()]} | {:error, term()}
  def list(filter \\ %{}, opts \\ []) when is_map(filter) do
    Repo.list_meetings(filter, opts)
  end

  @doc """
  Fails every row still in a live status and returns the ids it swept.

  Called once at boot: a live row with no Session behind it is a stranded
  record, and leaving it live would make `list(scope: :active)` lie forever.
  """
  @spec sweep_live(String.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def sweep_live(error_text, opts \\ []) when is_binary(error_text) do
    Repo.sweep_live_meetings(error_text, DateTime.utc_now(), opts)
  end

  @doc "Statuses that mean a Session should be alive for the row."
  @spec live_statuses() :: [String.t()]
  def live_statuses, do: MeetingsSql.live_statuses()
end
