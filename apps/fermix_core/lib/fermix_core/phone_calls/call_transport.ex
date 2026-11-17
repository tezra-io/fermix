defmodule FermixCore.PhoneCalls.CallTransport do
  @moduledoc """
  What a phone call's worker (`PhoneCalls.Call`) does on the wire, as one
  seam: the callbacks below, and this module's own implementation of them
  over the GPT-Live adapter (`OpenAILive`, `OpenAILive.Sideband`), the
  production transport. A test hands the worker a fake that implements the
  same callbacks and can reach no network, or runs this module itself against
  local stand-ins of the vendor.

  Every call here is one attempt: `create_session/2` places at most one call
  and is never repeated, `hangup/3` is the documented control sent once, and
  the sideband never reconnects. Credentials are arguments, resolved by the
  caller at the moment of the I/O; nothing here reads or keeps them. The
  sideband is handed both of a call's credentials, the API key it dials with
  and the trunk password, so that no word the vendor says during the call
  reaches the worker holding either (`OpenAILive.scrubber/1`).

  `opts` are the transport's wiring, decided once by the composition root
  (`FermixCore.Application.phone_call_transport_opts/2`) and handed to every
  call's worker and to the Manager's cleanup: the origins (`:base_url`,
  `:ws_base_url`) and the egress (`:egress`, a test's), passed through to
  `OpenAILive` and `Sideband`, or `refused: reason`, a build that must place
  no call through this transport (a test build, or a development build whose
  eval fixture origin is set and not honoured). A refused transport sends
  nothing: every create and hangup is `{:error, {:not_sent, reason}}`, every
  attach `{:error, reason}`, and the vendor is never the fallback.

  `manager_hangup/2` is the `:hangup` function `PhoneCalls.Manager` runs for a
  row no live worker owns: one single-attempt hangup of a known session, its
  key resolved when it runs.
  """

  alias FermixCore.PhoneCalls.Config
  alias FermixCore.PhoneCalls.OpenAILive
  alias FermixCore.PhoneCalls.OpenAILive.Sideband

  @callback create_session(OpenAILive.create_request(), keyword()) ::
              OpenAILive.create_result()
  @callback attach(session_id :: String.t(), credentials(), keyword()) ::
              {:ok, pid()} | {:error, term()}
  @callback attach_deadline_ms() :: pos_integer()
  @callback send_dtmf(pid(), String.t()) :: Sideband.send_result() | {:error, :invalid_dtmf_key}
  @callback send_commentary(pid(), String.t() | nil, String.t()) :: Sideband.send_result()
  @callback close(pid()) :: :ok
  @callback stop(pid()) :: :ok
  @callback hangup(session_id :: String.t(), api_key :: String.t(), keyword()) ::
              OpenAILive.hangup_result()

  @typedoc "A call's credentials, as the worker resolves them for one I/O."
  @type credentials :: %{
          required(:api_key) => String.t(),
          required(:sip_password) => String.t(),
          optional(atom()) => term()
        }

  @http_opts [:base_url, :ws_base_url, :egress]
  @ws_opts [:ws_base_url, :egress]

  @doc "Places the call: one `POST /v1/live/sessions`, never retried."
  @spec create_session(OpenAILive.create_request(), keyword()) :: OpenAILive.create_result()
  def create_session(request, opts) when is_map(request) and is_list(opts) do
    with :ok <- wired(opts),
         do: OpenAILive.create_session(request, Keyword.take(opts, @http_opts))
  end

  @doc """
  Attaches the sideband to `session_id` with the call's API key, linked to the
  caller; every word it hands the caller is scrubbed of the key and the trunk
  password.
  """
  @spec attach(String.t(), credentials(), keyword()) :: {:ok, pid()} | {:error, term()}
  def attach(session_id, %{api_key: api_key, sip_password: password}, opts)
      when is_binary(session_id) and is_binary(api_key) and is_binary(password) and
             is_list(opts) do
    case wired(opts) do
      :ok ->
        opts
        |> Keyword.take(@ws_opts)
        |> Keyword.merge(session_id: session_id, api_key: api_key, secrets: [password])
        |> Sideband.start_link()

      {:error, {:not_sent, reason}} ->
        {:error, reason}
    end
  end

  @doc "The bound on a whole attach (the sideband's connect plus its upgrade read)."
  @spec attach_deadline_ms() :: pos_integer()
  def attach_deadline_ms, do: Sideband.attach_deadline_ms()

  @doc "Presses one keypad key, once."
  @spec send_dtmf(pid(), String.t()) :: Sideband.send_result() | {:error, :invalid_dtmf_key}
  def send_dtmf(sideband, key) when is_pid(sideband) and is_binary(key),
    do: Sideband.send_dtmf(sideband, key)

  @doc "Spoken context: a delegation's result, or with `nil` something for the whole call."
  @spec send_commentary(pid(), String.t() | nil, String.t()) :: Sideband.send_result()
  def send_commentary(sideband, delegation_id, content)
      when is_pid(sideband) and is_binary(content),
      do: Sideband.send_commentary(sideband, delegation_id, content)

  @doc "Closes the sideband socket normally. Not ending the call: that is `hangup/3`."
  @spec close(pid()) :: :ok
  def close(sideband) when is_pid(sideband), do: Sideband.close(sideband)

  @doc "Stops a sideband that never attached in time; no exit signal follows."
  @spec stop(pid()) :: :ok
  def stop(sideband) when is_pid(sideband), do: Sideband.stop(sideband)

  @doc "The documented hangup control for `session_id`, sent once."
  @spec hangup(String.t(), String.t(), keyword()) :: OpenAILive.hangup_result()
  def hangup(session_id, api_key, opts)
      when is_binary(session_id) and is_binary(api_key) and is_list(opts) do
    with :ok <- wired(opts) do
      opts
      |> Keyword.take([:base_url, :egress])
      |> Keyword.put(:api_key, api_key)
      |> then(&OpenAILive.hangup(session_id, &1))
    end
  end

  @doc """
  The Manager's cleanup for a known session no worker owns: one hangup over
  the transport's wiring `opts`, the OpenAI Platform key resolved now (a
  refused transport resolves none). `:ok` when the vendor accepted it or said
  there was nothing to hang up (which is not proof that the call ended);
  otherwise the error, in the transport's words.
  """
  @spec manager_hangup(String.t(), keyword()) :: :ok | {:error, term()}
  def manager_hangup(session_id, opts)
      when is_binary(session_id) and session_id != "" and is_list(opts) do
    with :ok <- wired(opts),
         {:ok, api_key} <- Config.openai_api_key(),
         {:ok, _accepted_or_ended} <- hangup(session_id, api_key, opts) do
      :ok
    end
  end

  # A transport the composition root refused sends nothing and reads nothing.
  defp wired(opts) do
    case Keyword.fetch(opts, :refused) do
      {:ok, reason} -> {:error, {:not_sent, reason}}
      :error -> :ok
    end
  end
end
