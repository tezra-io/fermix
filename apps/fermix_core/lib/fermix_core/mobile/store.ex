defmodule FermixCore.Mobile.Store do
  @moduledoc """
  Durable, append-only storage for mobile companion profiles.

  This timeline is intentionally separate from the mutable conversation context:
  compaction and `/new` may rewrite prompt history, but they cannot rewrite rows
  already synchronized to a phone.
  """

  alias FermixCore.Memory.Config
  alias FermixCore.Memory.Repo
  alias FermixCore.Plugins.CanonicalJson

  @request_ttl_seconds 86_400
  @max_history_limit 200
  @default_history_limit 50
  @default_recovery_limit 50
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @type timeline_attrs :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:kind) => String.t(),
          optional(:client_msg_id) => String.t() | nil,
          optional(:in_reply_to) => String.t() | nil,
          optional(:media_refs) => [map()],
          optional(:metadata) => map() | nil,
          optional(:created_at) => DateTime.t()
        }

  @type request_status :: :running | :completed | :failed

  @spec append(String.t(), timeline_attrs(), keyword()) ::
          {:ok, Repo.mobile_timeline_row()} | {:error, term()}
  def append(profile_id, attrs, opts \\ []) when is_binary(profile_id) and is_map(attrs) do
    attrs
    |> Map.merge(profile_selector(profile_id, opts))
    |> Repo.append_mobile_timeline(repo_opts(opts))
  end

  @spec append_client_message(String.t(), String.t(), map(), keyword()) ::
          {:ok, {:created | :existing, Repo.mobile_timeline_row()}} | {:error, term()}
  def append_client_message(profile_id, client_msg_id, attrs, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_map(attrs) do
    attrs
    |> Map.merge(profile_selector(profile_id, opts))
    |> Map.put(:role, "user")
    |> Map.put(:client_msg_id, client_msg_id)
    |> Repo.append_mobile_client_message(repo_opts(opts))
  end

  @spec append_proactive(String.t(), String.t(), timeline_attrs(), keyword()) ::
          {:ok, {:created | :existing, Repo.mobile_timeline_row()}} | {:error, term()}
  def append_proactive(profile_id, dedupe_key, attrs, opts \\ [])
      when is_binary(profile_id) and is_binary(dedupe_key) and is_map(attrs) do
    attrs
    |> Map.merge(profile_selector(profile_id, opts))
    |> Map.put(:proactive_key, dedupe_key)
    |> Repo.append_mobile_proactive(repo_opts(opts))
  end

  @spec history_page(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def history_page(profile_id, opts \\ []) when is_binary(profile_id) do
    after_seq = Keyword.get(opts, :after_seq, 0)
    limit = Keyword.get(opts, :limit, @default_history_limit)

    with :ok <- validate_after_seq(after_seq),
         :ok <- validate_history_limit(limit) do
      Repo.get_mobile_history(
        profile_selector(profile_id, opts),
        after_seq,
        limit,
        repo_opts(opts)
      )
    end
  end

  @spec history_head(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def history_head(profile_id, opts \\ []) when is_binary(profile_id) do
    Repo.mobile_history_head(profile_selector(profile_id, opts), repo_opts(opts))
  end

  @spec media_descriptor(String.t(), String.t(), keyword()) ::
          {:ok, Repo.mobile_media_descriptor()}
          | {:error, :not_found | {:invalid_media_ref, String.t()} | term()}
  def media_descriptor(profile_id, ref, opts \\ [])
      when is_binary(profile_id) and is_binary(ref) do
    with :ok <- validate_media_ref(ref) do
      Repo.get_mobile_media_descriptor(profile_selector(profile_id, opts), ref, repo_opts(opts))
    end
  end

  @spec attach_timeline_media(String.t(), pos_integer(), map(), keyword()) ::
          {:ok, Repo.mobile_timeline_row()} | {:error, term()}
  def attach_timeline_media(profile_id, server_seq, media_ref, opts \\ [])
      when is_binary(profile_id) and is_integer(server_seq) and server_seq > 0 and
             is_map(media_ref) do
    Repo.attach_mobile_timeline_media(
      profile_selector(profile_id, opts),
      server_seq,
      media_ref,
      repo_opts(opts)
    )
  end

  @spec advance_read_frontier(String.t(), non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def advance_read_frontier(profile_id, reported_seq, opts \\ [])
      when is_binary(profile_id) and is_integer(reported_seq) and reported_seq >= 0 do
    Repo.advance_mobile_read_frontier(
      profile_selector(profile_id, opts),
      reported_seq,
      now(opts),
      repo_opts(opts)
    )
  end

  @spec read_frontier(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def read_frontier(profile_id, opts \\ []) when is_binary(profile_id) do
    Repo.get_mobile_read_frontier(profile_selector(profile_id, opts), repo_opts(opts))
  end

  @spec claim_client_request(String.t(), String.t(), String.t(), term(), keyword()) ::
          {:ok, {:claimed | :duplicate | :conflict, Repo.mobile_client_request_row()}}
          | {:error, term()}
  def claim_client_request(profile_id, client_msg_id, request_type, payload, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_binary(request_type) do
    claimed_at = now(opts)

    with {:ok, device_id} <- required_option(opts, :authenticated_device_id),
         {:ok, payload_digest} <- CanonicalJson.digest(payload) do
      Repo.claim_mobile_client_request(
        profile_selector(profile_id, opts),
        %{
          client_msg_id: client_msg_id,
          request_type: request_type,
          payload: payload,
          payload_digest: payload_digest,
          authenticated_device_id: device_id,
          claimed_at: claimed_at,
          expires_at: DateTime.add(claimed_at, @request_ttl_seconds, :second)
        },
        repo_opts(opts)
      )
    end
  end

  @spec get_client_request(String.t(), String.t(), keyword()) ::
          {:ok, Repo.mobile_client_request_row()} | {:error, :not_found | term()}
  def get_client_request(profile_id, client_msg_id, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) do
    Repo.get_mobile_client_request(
      profile_selector(profile_id, opts),
      client_msg_id,
      repo_opts(opts)
    )
  end

  @spec start_client_request(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, {:started | :active | :completed | :failed, Repo.mobile_client_request_row()}}
          | {:error, term()}
  def start_client_request(profile_id, client_msg_id, runner_epoch, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_binary(runner_epoch) do
    with :ok <- validate_nonempty(runner_epoch, :runner_epoch) do
      Repo.start_mobile_client_request(
        profile_selector(profile_id, opts),
        client_msg_id,
        runner_epoch,
        now(opts),
        repo_opts(opts)
      )
    end
  end

  @spec recoverable_client_requests(String.t(), keyword()) ::
          {:ok, [Repo.mobile_client_request_row()]} | {:error, term()}
  def recoverable_client_requests(runner_epoch, opts \\ []) when is_binary(runner_epoch) do
    limit = Keyword.get(opts, :limit, @default_recovery_limit)

    with :ok <- validate_nonempty(runner_epoch, :runner_epoch),
         :ok <- validate_recovery_limit(limit) do
      Repo.get_recoverable_mobile_client_requests(
        owner_selector(opts),
        runner_epoch,
        limit,
        now(opts),
        repo_opts(opts)
      )
    end
  end

  @spec settle_client_request(String.t(), String.t(), request_status(), map(), keyword()) ::
          {:ok, Repo.mobile_client_request_row()} | {:error, term()}
  def settle_client_request(profile_id, client_msg_id, status, fields, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_map(fields) do
    with {:ok, normalized_status} <- normalize_request_status(status),
         {:ok, attempt} <- required_attempt(fields) do
      Repo.settle_mobile_client_request(
        profile_selector(profile_id, opts),
        client_msg_id,
        normalized_status,
        Map.put(fields, :attempt, attempt),
        now(opts),
        repo_opts(opts)
      )
    end
  end

  @spec append_client_output(
          String.t(),
          String.t(),
          non_neg_integer(),
          String.t(),
          map(),
          keyword()
        ) ::
          {:ok, {:created | :existing, Repo.mobile_timeline_row()}} | {:error, term()}
  def append_client_output(profile_id, client_msg_id, attempt, output_key, attrs, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_map(attrs) do
    with :ok <- validate_attempt(attempt),
         :ok <- validate_nonempty(output_key, :output_key) do
      Repo.append_mobile_client_output(
        profile_selector(profile_id, opts),
        client_msg_id,
        attempt,
        output_key,
        attrs,
        now(opts),
        repo_opts(opts)
      )
    end
  end

  @spec complete_client_request(String.t(), String.t(), non_neg_integer(), map(), keyword()) ::
          {:ok, Repo.mobile_client_request_row()} | {:error, term()}
  def complete_client_request(profile_id, client_msg_id, attempt, fields, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_map(fields) do
    with :ok <- validate_attempt(attempt) do
      Repo.complete_mobile_client_request(
        profile_selector(profile_id, opts),
        client_msg_id,
        attempt,
        fields,
        now(opts),
        repo_opts(opts)
      )
    end
  end

  @spec fail_client_request(String.t(), String.t(), non_neg_integer(), map(), keyword()) ::
          {:ok, Repo.mobile_client_request_row()} | {:error, term()}
  def fail_client_request(profile_id, client_msg_id, attempt, fields, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_map(fields) do
    with :ok <- validate_attempt(attempt) do
      settle_client_request(
        profile_id,
        client_msg_id,
        :failed,
        Map.put(fields, :attempt, attempt),
        opts
      )
    end
  end

  @spec append_client_response(String.t(), String.t(), non_neg_integer(), map(), keyword()) ::
          {:ok, {:created | :existing, Repo.mobile_timeline_row()}} | {:error, term()}
  def append_client_response(profile_id, client_msg_id, attempt, attrs, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_map(attrs) do
    with :ok <- validate_attempt(attempt) do
      Repo.append_mobile_client_response(
        profile_selector(profile_id, opts),
        client_msg_id,
        attempt,
        attrs,
        now(opts),
        repo_opts(opts)
      )
    end
  end

  @spec update_client_message(String.t(), String.t(), non_neg_integer(), map(), keyword()) ::
          {:ok, Repo.mobile_timeline_row()} | {:error, term()}
  def update_client_message(profile_id, client_msg_id, attempt, attrs, opts \\ [])
      when is_binary(profile_id) and is_binary(client_msg_id) and is_map(attrs) do
    with :ok <- validate_attempt(attempt),
         :ok <- validate_update_attrs(attrs) do
      Repo.update_mobile_client_message(
        profile_selector(profile_id, opts),
        client_msg_id,
        attempt,
        attrs,
        repo_opts(opts)
      )
    end
  end

  defp profile_selector(profile_id, opts) do
    Map.put(owner_selector(opts), :profile_id, profile_id)
  end

  defp owner_selector(opts) do
    %{
      agent_id: Config.agent_id(opts),
      owner_id: Config.owner_id(opts)
    }
  end

  defp repo_opts(opts), do: [server: Config.repo_server(opts)]
  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now())

  defp validate_after_seq(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_after_seq(value), do: {:error, {:invalid_after_seq, value}}

  defp validate_history_limit(value)
       when is_integer(value) and value > 0 and value <= @max_history_limit,
       do: :ok

  defp validate_history_limit(value), do: {:error, {:invalid_history_limit, value}}

  defp validate_media_ref(ref) do
    if Regex.match?(@sha256, ref), do: :ok, else: {:error, {:invalid_media_ref, ref}}
  end

  defp validate_recovery_limit(value)
       when is_integer(value) and value > 0 and value <= @max_history_limit,
       do: :ok

  defp validate_recovery_limit(value), do: {:error, {:invalid_recovery_limit, value}}

  defp validate_attempt(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_attempt(value), do: {:error, {:invalid_attempt, value}}

  defp required_attempt(fields) do
    case Map.fetch(fields, :attempt) do
      {:ok, attempt} -> with :ok <- validate_attempt(attempt), do: {:ok, attempt}
      :error -> {:error, {:missing_field, :attempt}}
    end
  end

  defp required_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> with :ok <- validate_nonempty(value, key), do: {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp validate_nonempty(value, _key) when is_binary(value) and value != "", do: :ok
  defp validate_nonempty(value, key), do: {:error, {:invalid_field, key, value}}

  defp validate_update_attrs(attrs) do
    allowed = MapSet.new([:content, :media_refs, :metadata])

    case Enum.find(Map.keys(attrs), &(not MapSet.member?(allowed, &1))) do
      nil -> :ok
      key -> {:error, {:invalid_update_field, key}}
    end
  end

  defp normalize_request_status(status) when status in [:running, :completed, :failed] do
    {:ok, Atom.to_string(status)}
  end

  defp normalize_request_status(status) when status in ["running", "completed", "failed"] do
    {:ok, status}
  end

  defp normalize_request_status(status), do: {:error, {:invalid_request_status, status}}
end
