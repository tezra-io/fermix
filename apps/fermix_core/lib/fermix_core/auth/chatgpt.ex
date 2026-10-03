defmodule FermixCore.Auth.ChatGPT do
  @moduledoc """
  Sign in with ChatGPT: how the `openai_codex` provider signs in (M57), with its
  registration, sign-in, sign-out and standing. The one surface the web setup,
  the management sign-in, the terminal, the provider route and the doctor read;
  the OAuth details live behind it:

    * `ChatGPT.Login`: the browser sign-in and its redeem order.
    * `ChatGPT.TerminalLogin`: the same sign-in from a terminal, which also
      takes a pasted address.
    * `ChatGPT.Logout`: revoke upstream, clear the tokens, keep the registration.
    * `ChatGPT.Refresh`: the token managers' refresh of the `chatgpt` profile.
    * `ChatGPT.Registration`: the stored entry and what it means.
    * `ChatGPT.HostId` and `ChatGPT.IdToken`.

  A sign-in or a sign-out also tells a running token manager: a sign-in stops
  the `chatgpt` manager so its next use loads the new grant, a sign-out makes it
  drop its tokens (`TokenSupervisor.forget_signed_out/1`). Neither starts one.
  """

  alias FermixCore.Auth.ChatGPT.Login
  alias FermixCore.Auth.ChatGPT.Logout
  alias FermixCore.Auth.ChatGPT.Registration
  alias FermixCore.Auth.Redaction
  alias FermixCore.Auth.Store
  alias FermixCore.Auth.TokenSupervisor

  require Logger

  @type state :: :not_connected | :connected | :plan_off | :reconnect
  @type summary :: %{state: state(), account: String.t() | nil}
  @type route_error :: :not_signed_in | :plan_usage_off | :reconnect_needed

  @mismatch "The browser returned a different ChatGPT account than the one Fermix is " <>
              "connected to. Nothing was changed."
  @start_again "Start the sign-in again."

  @doc "The scope whose grant lets Fermix use the person's ChatGPT plan."
  @spec plan_scope() :: String.t()
  def plan_scope, do: Registration.plan_scope()

  @doc """
  Runs the browser sign-in in the calling process and stores the result.

  Options: `:fermix_path`, `:opener` (`nil` prints the url only), `:puts`,
  `:port`, `:timeout_ms`, `:req_options`. While it waits, the calling process
  also accepts a pasted callback address sent with `paste_callback/2`.
  """
  @spec login(keyword()) ::
          {:ok, %{account: String.t() | nil, plan_usage: :on | :off}} | {:error, term()}
  def login(opts \\ []) when is_list(opts) do
    :ok = validate_login_opts!(opts)

    case Login.run(opts) do
      {:ok, entry} ->
        :ok = TokenSupervisor.stop_profile(Registration.profile())
        {:ok, %{account: Store.account_label(entry), plan_usage: plan_usage(entry)}}

      {:error, reason} = error ->
        logged_failure("sign-in", reason)
        error
    end
  end

  @doc "Hands a pasted callback address to the sign-in running in `pid`."
  @spec paste_callback(pid(), String.t()) :: :ok
  def paste_callback(pid, url) when is_pid(pid) and is_binary(url) do
    send(pid, {:chatgpt_callback, url})
    :ok
  end

  @doc "Revokes the session upstream, then clears the tokens and keeps the registration."
  @spec logout(keyword()) :: {:ok, %{revoked: boolean()}} | {:error, term()}
  def logout(opts \\ []) when is_list(opts) do
    case Logout.run(opts) do
      {:ok, _result} = ok ->
        ok

      {:error, reason} = error ->
        logged_failure("sign-out", reason)
        error
    end
  end

  @doc "Where the stored registration stands, for a setup surface."
  @spec summary(keyword()) :: summary()
  def summary(opts \\ []) when is_list(opts) do
    case Registration.read(fermix_path(opts)) do
      {:ok, entry} ->
        state = Registration.state(entry)
        %{state: state, account: if(state != :not_connected, do: Store.account_label(entry))}

      {:error, reason} ->
        Logger.warning("ChatGPT: could not read the registration: #{Redaction.format(reason)}")
        %{state: :not_connected, account: nil}
    end
  end

  @doc "Whether a route may use the stored registration, and why not."
  @spec route_status(keyword()) :: :ok | {:error, route_error()}
  def route_status(opts \\ []) when is_list(opts) do
    case summary(opts).state do
      :connected -> :ok
      :plan_off -> {:error, :plan_usage_off}
      :reconnect -> {:error, :reconnect_needed}
      :not_connected -> {:error, :not_signed_in}
    end
  end

  @doc "The person-facing sentence for a sign-in, sign-out or route failure."
  @spec failure_sentence(term()) :: String.t()
  def failure_sentence(:plan_usage_off),
    do: "You're signed in, but ChatGPT plan usage is off. Turn it on to use your plan in Fermix."

  def failure_sentence(:not_signed_in),
    do: "Fermix isn't connected to ChatGPT. Continue with ChatGPT to connect it."

  def failure_sentence(reason) when reason in [:reconnect_needed, :reauthorization_required],
    do: "Your ChatGPT connection needs to be renewed. Sign in again."

  def failure_sentence(:access_denied), do: "Sign-in was cancelled in the browser."
  def failure_sentence(:client_mismatch), do: @mismatch
  def failure_sentence(:account_mismatch), do: @mismatch

  def failure_sentence(:revoke_not_confirmed),
    do:
      "Signed out on this computer, but ChatGPT didn't confirm the disconnect. You can " <>
        "disconnect Fermix in ChatGPT Settings > Security and login."

  def failure_sentence(:registration_incomplete),
    do: "ChatGPT didn't finish registering Fermix. " <> @start_again

  def failure_sentence(:identity_verification_unavailable),
    do:
      "Fermix couldn't reach OpenAI to verify your ChatGPT account. Check your connection " <>
        "and try again."

  def failure_sentence(:invalid_id_token),
    do: "Fermix couldn't verify the ChatGPT account the browser returned. Nothing was changed."

  def failure_sentence(:profile_busy), do: Store.busy_sentence()

  def failure_sentence(:callback_timeout),
    do: "The ChatGPT sign-in timed out before the browser came back. " <> @start_again

  def failure_sentence({:port_in_use, port}),
    do:
      "Port #{port} on 127.0.0.1 is already in use, so Fermix can't wait for the browser " <>
        "there. Free the port or choose another one."

  def failure_sentence({:token_exchange_failed, _detail}),
    do: "ChatGPT didn't accept this sign-in. " <> @start_again

  def failure_sentence(:invalid_token_response),
    do: "ChatGPT's answer to the sign-in was incomplete. " <> @start_again

  def failure_sentence(reason) when reason in [:missing_code, :invalid_callback],
    do: "The browser came back without a usable sign-in code. " <> @start_again

  def failure_sentence({:authorization_error, code}),
    do: "ChatGPT stopped the sign-in (#{code}). " <> @start_again

  def failure_sentence(reason), do: host_id_sentence(reason) || generic_sentence(reason)

  defp host_id_sentence({:host_id_insecure_permissions, file, mode}),
    do:
      "#{file} has permissions 0o#{Integer.to_string(mode, 8)}; it must be 0o600. " <>
        "Run `chmod 600 #{file}` and sign in again."

  defp host_id_sentence({:host_id_symlink, file}),
    do: "#{file} is a symbolic link. Replace it with the file itself and sign in again."

  defp host_id_sentence({kind, file}) when kind in [:host_id_invalid, :host_id_not_a_file],
    do:
      "#{file} doesn't hold a ChatGPT host id Fermix can use. Move it aside and sign in " <>
        "again; Fermix then registers this computer as a new host."

  defp host_id_sentence({:host_id_unreadable, file, reason}),
    do: "Fermix couldn't read #{file} (#{inspect(reason)})."

  defp host_id_sentence(_reason), do: nil

  defp generic_sentence(reason),
    do: "ChatGPT sign-in failed (#{Redaction.format(reason)})."

  defp plan_usage(entry), do: if(Registration.plan_usage?(entry), do: :on, else: :off)

  defp fermix_path(opts), do: Keyword.get(opts, :fermix_path, Store.path())

  defp validate_login_opts!(opts) do
    case Keyword.get(opts, :port) do
      nil -> :ok
      port when is_integer(port) and port in 0..65_535 -> :ok
      other -> raise ArgumentError, ":port must be a port number, got: #{inspect(other)}"
    end
  end

  defp logged_failure(what, reason) do
    Logger.warning("ChatGPT #{what} failed: #{kind(reason)} (#{Redaction.format(reason)})")
  end

  defp kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp kind(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: "#{elem(reason, 0)}"
  defp kind(_reason), do: "failed"
end
