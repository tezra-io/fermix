defmodule FermixCore.Browser.SignIn do
  @moduledoc """
  The `browser` tool's `act kind=sign_in`: a login the owner saved in the
  Fermix Mac app, typed into the page in front of the model.

  Three steps, in the tool call's own process, in order:

    1. `login_for` on the turn's profile (`page.login_for` on host protocol
       2): which saved login fits the page, by its site and username. No
       secret moves, and a page with no saved login is answered
       `sign_in_no_login` here, before anyone is asked.
    2. Only when the call names `password_ref`, the owner is asked inside the
       call (`AccessGate.ask_in_call/3`): "Sign in to github.com as alice?".
       The call waits for the answer, at most `Timeouts.sign_in_approval/0`. A
       call with `username_ref` alone is not asked about: it types only the
       saved username, only into the saved site's own page, and tells the
       model nothing it did not have.
    3. `sign_in` on the same profile, task and tab (`page.sign_in`): the app
       checks the page again, reads the password from its keychain and types
       it.

  No profile is held while the owner decides: each step is its own request
  and the wait is between them, here. The pane task and its tab outlive the
  wait because the task is bound to this process (`HostServer`) and the
  profile's idle bound is far longer than the wait. Nothing else of the turn
  runs meanwhile, because a step's tool calls run one after another in this
  process.

  The engine never holds the password: the app reads it and types it. What
  comes back is the site, the username and which fields were filled.
  """

  alias FermixCore.Browser
  alias FermixCore.Browser.Capabilities
  alias FermixCore.Browser.Error
  alias FermixCore.Browser.Policy
  alias FermixCore.BrowserHost.Protocol
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Timeouts

  @typedoc "Runs one request on the turn's profile, as `ProfileManager.dispatch/6` answers."
  @type route :: (map() -> {:ok, map()} | {:error, Error.t()})

  @refs ~w(username_ref password_ref)

  @doc """
  The canonical spelling of a sign-in's `site`, or why it is refused.

  `Policy.canonical_host/1` gives the one spelling Fermix and the browser
  agree on, and accepts address literals, which a site is not: a login is
  saved for a name, and a loopback or private address is whatever server a
  command started there. So an address, `localhost` (and its subdomains), a
  dotless name and an empty label are refused too.
  """
  @spec site(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def site(site) when is_binary(site) and site != "" do
    case Policy.canonical_host(site) do
      {:ok, host} -> named_site(host)
      :error -> refused_site("this one has characters a host name does not")
    end
  end

  def site(_site) do
    {:error,
     Error.new(
       "missing_arg",
       "sign_in requires `site`: the host of the page in front of you, as its address " <>
         "shows it (like github.com)."
     )}
  end

  @doc """
  Whether a `sign_in` call's arguments have the shape one needs: a `site`, at
  least one of `username_ref` and `password_ref` (refs from the latest
  snapshot), and no `text`, since the login typed is the owner's saved one.
  """
  @spec validate(map()) :: :ok | {:error, Error.t()}
  def validate(args) when is_map(args) do
    with {:ok, _site} <- site(Map.get(args, "site")),
         :ok <- no_text(args) do
      refs(args)
    end
  end

  @doc """
  Run a validated `sign_in` call on the turn's profile, whose routed `mode`
  decides whether it can sign in at all. `route` sends one request to that
  profile.
  """
  @spec run(map(), map(), atom(), route()) :: {:ok, map()} | {:error, Error.t()}
  def run(args, context, mode, route)
      when is_map(args) and is_map(context) and is_atom(mode) and is_function(route, 1) do
    if Capabilities.allows?(mode, :sign_in),
      do: run_signed(args, context, route),
      else: Capabilities.refuse(mode, :sign_in)
  end

  defp run_signed(args, context, route) do
    {:ok, site} = site(args["site"])

    with {:ok, login} <- route.(login_request(args, site, context)),
         :ok <- approved(args, site, login, context),
         {:ok, receipt} <- route.(sign_in_request(args, site, login, context)) do
      {:ok, Map.merge(receipt, %{"site" => site, "username" => login["username"]})}
    end
  end

  # A read: repeating it after a dead server repeats nothing.
  defp login_request(args, site, context) do
    %{
      action: "login_for",
      args: %{"target" => args["target"], "site" => site},
      context: context,
      mutating: false
    }
  end

  # On the tab `login_for` was answered on, whichever tab is active by then,
  # and never re-sent after a dead server (`Browser.mutating?/2`).
  defp sign_in_request(args, site, login, context) do
    %{
      action: "sign_in",
      args:
        args
        |> Map.take(@refs)
        |> Map.merge(%{
          "target" => login["target"],
          "site" => site,
          "login_site" => login["login_site"]
        }),
      context: context,
      mutating: Browser.mutating?("act", args)
    }
  end

  # ── the owner's answer ─────────────────────────────────────────────────────

  defp approved(%{"password_ref" => ref}, site, login, context) when is_binary(ref) do
    site
    |> prompt(login)
    |> AccessGate.ask_in_call(context, Timeouts.sign_in_approval())
    |> answer()
  end

  defp approved(_username_only, _site, _login, _context), do: :ok

  # The login that will be used, as the app named it. The second form appears
  # only when the page's host and the site the login is saved for differ, which
  # is the `www.` fold.
  defp prompt(site, %{"login_site" => site, "username" => username}),
    do: "Sign in to #{AccessGate.visible(site)} as #{AccessGate.visible(username)}?"

  defp prompt(site, %{"login_site" => login_site, "username" => username}) do
    "Sign in to #{AccessGate.visible(site)} as #{AccessGate.visible(username)}, with the " <>
      "login saved for #{AccessGate.visible(login_site)}?"
  end

  defp answer({:ok, :confirmed}), do: :ok

  defp answer({:error, :denied}) do
    {:error,
     Error.new(
       "sign_in_denied",
       "The owner said no to this sign-in, so nothing was typed. Do not ask again or sign " <>
         "in another way; tell the owner it was not done."
     )}
  end

  defp answer({:error, :unanswered}) do
    seconds = div(Timeouts.sign_in_approval(), 1_000)

    {:error,
     Error.new(
       "sign_in_unanswered",
       "The owner did not answer the sign-in question within #{seconds} seconds, so nothing " <>
         "was typed. Tell the owner, and ask again once they are back."
     )}
  end

  defp answer({:error, {:not_delivered, reason}}) do
    {:error,
     Error.new(
       "sign_in_not_delivered",
       "Fermix could not put the sign-in question in front of the owner, so nothing was " <>
         "typed. Ask the owner to make the request from their own chat or the Fermix app.",
       %{"reason" => reason |> inspect(limit: 5, printable_limit: 120) |> String.slice(0, 200)}
     )}
  end

  # ── arguments ──────────────────────────────────────────────────────────────

  defp named_site(host) do
    cond do
      String.length(host) > Protocol.max_site_chars() ->
        refused_site("this one is longer than a host name can be")

      address?(host) ->
        refused_site("#{host} is an address, not a site's name")

      localhost?(host) ->
        refused_site("#{host} is this computer, not a website")

      not String.contains?(host, ".") ->
        refused_site("#{host} has no dot")

      "" in String.split(host, ".") ->
        refused_site("#{host} has an empty label")

      true ->
        {:ok, host}
    end
  end

  # An IPv6 literal keeps its colons through `canonical_host/1`; an IPv4 one is
  # any name whose last label is a number, which is how the browser's own URL
  # parser reads it (`127.1`, `0x7f.1` and `2130706433` all reach 127.0.0.1).
  defp address?(host) do
    last = host |> String.split(".") |> List.last()

    String.contains?(host, ":") or
      match?({:ok, _ip}, :inet.parse_address(String.to_charlist(host))) or
      Regex.match?(~r/\A(?:\d+|0x[0-9a-f]*)\z/, last)
  end

  defp localhost?(host), do: host == "localhost" or String.ends_with?(host, ".localhost")

  defp refused_site(reason) do
    {:error,
     Error.new(
       "sign_in_field",
       "`site` must be the host name of the page in front of you, as its address shows it " <>
         "(like github.com); #{reason}. Nothing was typed."
     )}
  end

  defp no_text(args) do
    if Map.has_key?(args, "text") do
      {:error,
       Error.new(
         "invalid_arg",
         "sign_in takes no `text`: it types the login the owner saved in the Fermix app, " <>
           "after they approve. Never type a password yourself."
       )}
    else
      :ok
    end
  end

  defp refs(args) do
    given = Enum.reject(@refs, &is_nil(Map.get(args, &1)))

    cond do
      given == [] ->
        {:error,
         Error.new(
           "missing_arg",
           "sign_in requires `username_ref`, `password_ref` or both: the login form's fields " <>
             "from the latest snapshot."
         )}

      Enum.all?(given, &ref?(Map.get(args, &1))) ->
        :ok

      true ->
        {:error,
         Error.new(
           "invalid_arg",
           "`username_ref` and `password_ref` must be element refs from the latest snapshot."
         )}
    end
  end

  defp ref?(ref), do: is_binary(ref) and ref != ""
end
