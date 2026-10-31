defmodule FermixCore.Home.Provision do
  @moduledoc """
  The contract every cloud provider Always On creates a server on implements
  (M75 lean v1 §4.3, L1, L2): one behaviour in the engine, so both apps and
  the CLI share one implementation over management
  (`FermixCore.Management.Provision`, `home.provision.*`). This is where a new
  provider plugs in: a module implementing the callbacks below, listed in
  `Provision.Registry` (one provider today).

  Everything provider-specific lives in the provider's module: its API, its
  label and naming rules, how it reads prices, its error codes, its
  locations, its system image and what it answers that must never be kept.
  The shared code (this module's own functions, `Provision.Ledger`,
  `Provision.FirstBoot`, the job, the summary, `Management.Copy` and the
  management family) reaches a provider only through the callbacks and its
  display data, and names none.

  A provider keeps its token and what it created in one ledger file of its
  own (`Provision.Ledger`, `device/provision/<id>.json`), written before each
  call that creates or deletes and updated after it. The callbacks:

    * `id/0`: the provider's id, its ledger's file name and what the wire
      calls it (lower case, as `"examplecloud"`).
    * `display/0`: what the apps draw and the shared sentences say of it
      (`t:display/0`): its name, the token field's label, the "How to get
      one" steps (two-factor sign-in first and an account for Fermix alone,
      L20), its console and docs section, its locations and the proper nouns
      its words use.
    * `type_name/1`: a server type as its console names it.
    * `check_token/2`: reads the account, so a token the provider refuses is
      named at once; answers whether the account holds servers Fermix did
      not create (Details says "Fermix only touches what it creates").
    * `reaches/3`: whether a new token is of the account the ledger's server
      (or firewall) is in, so a token for another account never replaces the
      one that reaches what Fermix created.
    * `options/2`: the orderable types per location with their monthly
      prices as the account is billed (VAT included), and the L2
      recommendation, read live.
    * `create/3`: what the server needs before it (a firewall with no inbound
      rule first, where a read-only token fails before anything costs money),
      then the server with the first boot (`Provision.FirstBoot`) and a fresh
      24-hour enrollment code as its user data, each write's action polled
      with a bound.
    * `power/3`: turns the server on, or restarts it.
    * `reconcile/2`: reads what the ledger names from the provider: a
      resource deleted outside Fermix is marked gone, a server's power is
      recorded (`"running"`, `"off"`, or another word of the provider's), and
      a create whose answer was lost is found again by its labels.
    * `delete/2`: the server, then its addresses unless they went with it,
      then the firewall.
    * `delete_replaced/2`: the same, in the same order, for the server a
      replace retired (`Ledger.retired/1`), never one that still holds the
      home; the ledger then keeps that the replace is done.

  A provider answers its own refusals as one of a small closed set of shared
  kinds (`t:provider_error/0`), so the shared code words them alike for every
  provider: the token refused (`:unauthorized`, which is "does not accept"
  when pasted and "no longer accepts" after), a read-only token, the
  account's limit, no capacity where asked (with the next location in
  stock), the rate limit, no answer, another account's token, or any other
  refusal as the provider's own plain sentence (`{:other, sentence}`). The
  rest of `t:reason/0` is the engine's own. Every reason is one sentence
  (`error_sentence/2`, in the provider's words where it names it) and one
  word the ledger keeps (`failure_word/1`).

  Names and labels (`server_name/2`, `labels/2`): a server is named
  `fermix-<profile>-<ref>`, `ref` four hex digits from the ledger, so a new
  server never collides with one it replaces, and every resource carries
  `fermix=always-on`, `fermix-profile=<profile>` and `fermix-ref=<ref>`, the
  profile sanitised to label rules strict enough for every provider (lower
  case, digits and hyphens).

  A provider served by an external plugin (not built) would be a module of
  this contract inside the engine that forwards each callback to the plugin.
  The engine keeps what it keeps for every provider: the token's custody
  (read from the ledger and passed with each call, never stored by the
  plugin), the owner's decisions over connect, create, power and delete
  (`Fermix.CLI.Daemon`), the enrollment code's window, and the ledger, whose
  write-ahead steps would move out of the provider module into a shared
  driver first, so that the plugin answers single steps (create the
  firewall, create the server, read one resource, delete one) with the
  shared error kinds.
  """

  alias FermixCore.Home.Provision.Ledger

  @typedoc """
  A provider's own refusal, as the shared code words it: the closed set every
  provider maps its errors to.
  """
  @type provider_error ::
          :unauthorized
          | :read_only_token
          | :account_limit
          | {:unavailable, capacity()}
          | {:rate_limited, integer() | nil}
          | {:unreachable, String.t()}
          | :other_project
          | {:other, String.t()}

  @typedoc """
  No capacity where asked: the type (`description` as the provider names it)
  and the location (`city`), and the next location in stock (`next`,
  `next_city`), or nil.
  """
  @type capacity :: %{
          required(:description) => String.t(),
          required(:city) => String.t(),
          required(:next_city) => String.t() | nil,
          optional(atom()) => term()
        }

  @type reason ::
          provider_error()
          | :token_invalid
          | :token_refused
          | {:code_unavailable, String.t()}
          | :user_data_too_large
          | :invalid_code
          | :interrupted
          | :no_token
          | :no_server
          | :server_exists
          | :nothing_to_delete
          | :not_primary
          | :live_home
          | :move_under_way
          | :replace_only
          | :nothing_to_replace
          | :replacement_exists
          | :replace_moving
          | :old_server_remains
          | :replacement_gone
          | :no_link
          | :code_unreachable
          | :withdraw_unreachable
          | :unreadable
          | {:code_refused, String.t()}
          | {:withdraw_refused, String.t()}
          | {:old_server, reason()}
          | {:ledger, term()}

  @typedoc """
  A provider's display data:

    * `name`: how every sentence names it ("ExampleCloud");
    * `token_label`: the token field's label, read after "a" in a sentence
      ("ExampleCloud API token");
    * `write_token`: the token Fermix needs, with its article ("a token
      that may create servers");
    * `account`: what a token belongs to, as the provider calls it
      ("project", "workspace");
    * `steps`: "How to get one", two-factor sign-in first and an account for
      Fermix alone (L20);
    * `console_url`: the provider's console, which Open <name> opens;
    * `docs_anchor`: its section of the Always On docs page;
    * `locations`: where Fermix creates a server, `{id, city}`, in the order
      it recommends them;
    * `proper_nouns`: the names its words use, which the copy rules accept
      (`Management.Copy`).
  """
  @type display :: %{
          name: String.t(),
          token_label: String.t(),
          write_token: String.t(),
          account: String.t(),
          steps: [String.t(), ...],
          console_url: String.t(),
          docs_anchor: String.t(),
          locations: [%{id: String.t(), city: String.t()}, ...],
          proper_nouns: [String.t(), ...]
        }

  @typedoc """
  What a create asks for: the type and location (`options/2` names them) and
  the profile the server is named and labelled by.
  """
  @type request :: %{type: String.t(), location: String.t(), profile: String.t()}

  @typedoc """
  The seams every callback takes: `:req_options` (merged into each request,
  a test's plug), `:now` (a 0-arity clock), `:sleep` (the pause between two
  polls), `:report` (the job's phase reporter), `:open_code` (a 0-arity
  function answering a fresh provisioned enrollment code) and
  `:withdraw_code` (closing that window when its server will not exist).
  """
  @type opts :: keyword()

  @callback id() :: String.t()
  @callback display() :: display()
  @callback type_name(String.t()) :: String.t()
  @doc """
  Whether `token` reaches what the ledger holds: one read, by id, of its
  server (or else its firewall) that is not gone; `{:error,
  :other_project}` when the provider says it has no such thing for this
  token. Nothing standing is reached by any token.
  """
  @callback reaches(String.t(), Ledger.t(), opts()) :: :ok | {:error, reason()}
  @callback check_token(String.t(), opts()) ::
              {:ok, %{other_servers: boolean()}} | {:error, reason()}
  @callback options(String.t(), opts()) :: {:ok, map()} | {:error, reason()}
  @callback create(Path.t(), request(), opts()) :: {:ok, Ledger.server()} | {:error, reason()}
  @callback power(Path.t(), :on | :reset, opts()) :: :ok | {:error, reason()}
  @callback reconcile(Path.t(), opts()) :: {:ok, Ledger.t()} | {:error, reason()}
  @callback delete(Path.t(), opts()) :: :ok | {:error, reason()}
  @callback delete_replaced(Path.t(), opts()) :: :ok | {:error, reason()}

  @doc "The provider of `providers` (the registry's list) whose id is `id`."
  @spec provider([module(), ...], term()) :: {:ok, module()} | :error
  def provider([_ | _] = providers, id) do
    case Enum.find(providers, &(&1.id() == id)) do
      nil -> :error
      provider -> {:ok, provider}
    end
  end

  @doc """
  The provider Always On speaks of under `home`, of `providers` (the
  registry's list, in the order it offers them): the one whose ledger holds
  what Fermix created, or cannot be read (it may hold a server); else the one
  whose token was given last; else the first offered. Fermix creates on one
  provider at a time (`Management.Provision` refuses a create while another
  holds a server), so at most one holds anything.
  """
  @spec current(Path.t(), [module(), ...]) :: module()
  def current(home, [first | _] = providers) when is_binary(home) do
    readings = Enum.map(providers, &{&1, Ledger.read(home, &1.id())})
    holding(readings) || latest_token(readings) || first
  end

  defp holding(readings) do
    Enum.find_value(readings, fn
      {provider, {:error, _reason}} -> provider
      {provider, {:ok, ledger}} -> if Ledger.holding?(ledger), do: provider
    end)
  end

  defp latest_token(readings) do
    connected =
      for {provider, {:ok, %{token: token, connected_at: %DateTime{} = at}}} <- readings,
          is_binary(token),
          do: {provider, at}

    case connected do
      [] -> nil
      _some -> connected |> Enum.max_by(&elem(&1, 1), DateTime) |> elem(0)
    end
  end

  @doc "The city of `location`, one of the provider's own (`display/0`'s `locations`)."
  @spec city(module(), String.t()) :: String.t()
  def city(provider, location) when is_binary(location) do
    %{city: city} = Enum.find(provider.display().locations, &(&1.id == location))
    city
  end

  @doc "The ids of the locations the provider creates a server in, in its order."
  @spec location_ids(module()) :: [String.t()]
  def location_ids(provider), do: Enum.map(provider.display().locations, & &1.id)

  @doc """
  The provider's cities as a sentence lists them: "Oslo", "Oslo or Lisbon",
  "Falkenstein, Nuremberg or Helsinki".
  """
  @spec cities(module()) :: String.t()
  def cities(provider) do
    case Enum.map(provider.display().locations, & &1.city) do
      [city] -> city
      cities -> Enum.join(Enum.drop(cities, -1), ", ") <> " or " <> List.last(cities)
    end
  end

  @max_profile_label 40

  @doc "The server's name for `profile` and the ledger's `ref`."
  @spec server_name(String.t(), String.t()) :: String.t()
  def server_name(profile, ref) when is_binary(profile) and is_binary(ref),
    do: "fermix-#{name_part(profile)}-#{ref}"

  @doc """
  A server's short id from two random bytes: four hex digits, never `avoid`
  (the id of the server a replace keeps until the move to the new one is
  done), so the new server's name and labels never collide with the old
  one's.
  """
  @spec fresh_ref(<<_::16>>, String.t() | nil) :: String.t()
  def fresh_ref(<<value::16>>, avoid) when is_binary(avoid) or is_nil(avoid) do
    ref = hex4(value)
    if ref == avoid, do: hex4(rem(value + 1, 0x10000)), else: ref
  end

  defp hex4(value),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")

  @doc """
  `profile` as a part of a server's name: lower-case letters and digits,
  runs of anything else one hyphen, at most #{@max_profile_label} characters,
  never starting or ending with a hyphen, so it is also a label or tag value
  every provider takes. A profile with nothing left is named by its digest
  (`p` and eight hex digits).
  """
  @spec name_part(String.t()) :: String.t()
  def name_part(profile) when is_binary(profile) do
    profile
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, @max_profile_label)
    |> String.trim("-")
    |> named(profile)
  end

  defp named("", profile),
    do:
      "p" <>
        (:sha256 |> :crypto.hash(profile) |> Base.encode16(case: :lower) |> binary_part(0, 8))

  defp named(value, _profile), do: value

  @doc "The word the ledger keeps for why a create stopped."
  @spec failure_word(reason()) :: String.t()
  def failure_word({:old_server, reason}), do: failure_word(reason)
  def failure_word({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  def failure_word(reason) when is_atom(reason), do: Atom.to_string(reason)

  @doc """
  One sentence for `reason`, in the daemon's words and `provider`'s where it
  names it (`display/0`), or the provider's own (`{:other, sentence}`):
  plain words, with no code or HTTP status, since the summary prints a
  create's failure as it is.
  """
  @spec error_sentence(reason(), module()) :: String.t()
  def error_sentence(reason, provider) when is_atom(provider),
    do: sentence(reason, provider.display())

  defp sentence(:token_invalid, words),
    do:
      "#{words.name} does not accept this token, so paste #{words.write_token} from the " <>
        "#{words.name} #{words.account} you made for Fermix."

  defp sentence(reason, words) when reason in [:unauthorized, :token_refused],
    do: "#{words.name} no longer accepts Fermix's token."

  defp sentence(:read_only_token, words),
    do:
      "This token can only read, so Fermix created nothing; paste #{words.write_token} " <>
        "from your #{words.name} #{words.account}."

  defp sentence(:account_limit, words), do: "#{words.name} limits new servers on this account."

  defp sentence({:unavailable, %{city: city, description: type, next_city: nil}}, _words),
    do: "No location Fermix offers has a #{type} right now, #{city} included."

  defp sentence({:unavailable, %{city: city, description: type}}, _words),
    do: "#{city} has no #{type} right now."

  defp sentence({:rate_limited, _reset}, words),
    do: "#{words.name} is limiting how often Fermix may ask, so try again in a few minutes."

  defp sentence({:unreachable, _reason}, words),
    do:
      "Fermix could not reach #{words.name}, so check this computer's connection and try " <>
        "again."

  defp sentence(:other_project, words),
    do:
      "This token is for another #{words.name} #{words.account} than the server Fermix " <>
        "created, so paste a token from that #{words.account}."

  defp sentence({:other, sentence}, _words) when is_binary(sentence), do: sentence
  defp sentence({:code_unavailable, sentence}, _words), do: sentence

  defp sentence(:user_data_too_large, words),
    do: "The setup Fermix puts on a new server is larger than #{words.name} takes."

  defp sentence(:invalid_code, _words),
    do: "Fermix made an enrollment code it could not put on the server, so start again."

  defp sentence(:interrupted, _words),
    do: "Fermix stopped before your server was created, so start again."

  defp sentence(:no_token, words), do: "Paste a #{words.token_label} first."

  defp sentence(:no_server, words),
    do: "Fermix has no server on #{words.name} to turn on or restart."

  defp sentence(:server_exists, _words),
    do: "Your server already exists, so delete it before creating another."

  defp sentence(:nothing_to_delete, words),
    do: "Fermix created nothing on #{words.name} to delete."

  defp sentence(:not_primary, _words),
    do:
      "Fermix runs on your server now, so it creates no other one from here; to replace " <>
        "that server, get a code in Always On and use it on a Linux server of your own."

  defp sentence(:live_home, _words),
    do:
      "Your server runs Fermix now, so Fermix does not delete it; replace the server " <>
        "instead."

  defp sentence(:move_under_way, _words),
    do: "Fermix is moving to your server, so it is not deleted while the move runs."

  defp sentence(:replace_only, _words),
    do: "Fermix runs on your server now, so a new server from here can only replace it."

  defp sentence(:nothing_to_replace, _words),
    do: "Fermix runs on this computer, so there is no server to replace yet."

  defp sentence(:replacement_exists, _words),
    do: "Your new server already exists, so delete it before creating another."

  defp sentence(:replace_moving, _words),
    do: "Fermix is moving to your new server, so it creates no other one until the move is done."

  defp sentence(:old_server_remains, _words),
    do: "Your old server still exists, so delete it before replacing this one."

  defp sentence(:replacement_gone, words),
    do: "Your new server was deleted in #{words.name}, so replace the server again."

  defp sentence(:no_link, _words),
    do:
      "Fermix could not read how this computer reaches your server, so it created nothing; " <>
        "Fermix's log says why."

  defp sentence(:code_unreachable, _words),
    do:
      "Fermix cannot reach your server to get a code for the new one, so try again once your " <>
        "server is back."

  defp sentence(:withdraw_unreachable, _words),
    do:
      "Fermix cannot reach your server to close the code it gave the new one, so try again " <>
        "once your server is back."

  defp sentence({:code_refused, _code}, _words),
    do: "Your server did not open a code for the new one."

  defp sentence({:withdraw_refused, _code}, _words),
    do: "Your server did not close the code it gave the new one."

  defp sentence({:old_server, reason}, words),
    do: "Fermix could not delete your old server: #{sentence(reason, words)}"

  defp sentence({:ledger, _reason}, words),
    do: "Fermix could not keep its #{words.name} file; Fermix's log says why."

  defp sentence(:unreadable, words),
    do:
      "Fermix could not read its #{words.name} file, so it shows nothing it created there; " <>
        "Fermix's log says why."
end
