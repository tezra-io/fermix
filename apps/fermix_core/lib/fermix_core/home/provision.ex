defmodule FermixCore.Home.Provision do
  @moduledoc """
  The contract every cloud provider Always On creates a server on implements
  (M75 lean v1 §4.3, L1, L2), and where a new provider plugs in: a module of
  the callbacks below, listed in `Provision.Registry` (one provider today).
  A provider is only an API adapter. Its callbacks are the provider's own
  primitive operations, each one call (or a fixed few) to its API, answering
  normalized facts and the closed set of kinds below; everything around them
  is shared, in `Provision.Driver`: every ledger write before a call and
  after it, the order (firewall, image, enrollment code, server, its start),
  the labels, the polling and its bounds, a lost create found again by its
  labels, the reconcile, the delete order and its guard, the code window,
  and the L2 offer (`Provision.Offering`). Both apps and the CLI reach it
  over management (`FermixCore.Management.Provision`, the steps `home.act`
  runs).

  What stays in a provider's module is what only it knows: its API (its
  endpoints, how it encodes labels and finds by them, how it writes prices,
  its error codes and their mapping), its locations and their cities, its
  system image, its user data limit and anything its answers carry that must
  never be kept (a root password, dropped where the answer arrives).
  The shared code names no provider.

  The plug-in surface (`opts` carries the provider's own seams, such as a
  test's request plug, untouched by the driver):

    * identity: `id/0` (the ledger's file name and the wire's id, lower
      case, as `"examplecloud"`), `display/0` (`t:display/0`), `type_name/1`
      (a type as its console names it) and `max_user_data/0` (the most bytes
      of user data a server takes);
    * `check_token/2`: reads the account; whether it holds servers Fermix did
      not create;
    * `catalog/2`: what the account can order now, `t:catalog/0`: every
      type with its shape, where it is in stock and its monthly price there,
      each place's IPv4 price, the currency and the places' names;
    * `server_type/3`: one type as sold now, and the places' names, so a
      create checks stock before anything is written;
    * `system_image/2`: the Debian 13 image to create from, as the provider
      names it;
    * `create_firewall/3`: a firewall with no inbound rule, named and
      labelled (`t:labels/0`) as given;
    * `create_server/3`: the server (`t:server_spec/0`), started, with the
      firewall and the user data; answers `t:created/0`;
    * `power/4`: turns a server on, or restarts it; answers its action;
    * `action/3`: reads one action (`t:action/0`);
    * `get/4`, `find/4`: one resource by id, or by its labels
      (`t:resource/0`); a server's power is `"running"`, `"off"` or another
      word of the provider's;
    * `delete/4`: deletes one resource; a server answers its action.

  Ids are the provider's own and opaque to Fermix: strings. A provider
  answers its refusals as one of a closed set (`t:error/0`): the shared kinds
  every sentence words alike (the token refused, a read-only token, the
  account's limit, the rate limit, no answer, the provider's own refusal as
  a plain sentence in `{:other, sentence}`), the kinds the driver reads
  (`:not_found`, `:in_use` for a firewall its server still holds,
  `:no_capacity` where the server was asked for, `:no_image`), and
  `{:unknown, error}` when a write may have been carried out (no answer, a
  server error, a name it already holds), which the driver keeps for the
  reconcile to find. Every reason the driver and the management family
  answer (`t:reason/0`) is one sentence (`error_sentence/2`, in the
  provider's words where it names it) and one word the ledger keeps
  (`failure_word/1`).

  Names and labels (`server_name/2`, `labels/2`): a server is named
  `fermix-<profile>-<ref>`, `ref` four hex digits from the ledger, so a new
  server never collides with one it replaces, and every resource carries
  `fermix=always-on`, `fermix-profile=<profile>` and `fermix-ref=<ref>`, the
  profile lower case, digits and hyphens, which every provider can store.

  A provider served by an external plugin (not built) would be a module of
  this contract in the engine that forwards each primitive to the plugin, the
  token passed with each call. The engine keeps what it keeps for every
  provider: the token's custody (in the provider's ledger, never stored by
  the plugin), the owner's decisions over connect, create, power and delete
  (`Fermix.CLI.Daemon`), the enrollment code's window, the display data the
  apps draw, and the ledger, which only the driver writes.
  """

  alias FermixCore.Home.Provision.Ledger

  @typedoc "A resource's id: the provider's own, opaque to Fermix."
  @type id :: String.t()

  @typedoc "What a primitive acts on: a server, a firewall or a primary address."
  @type kind :: :server | :firewall | :primary_ip

  @typedoc "The labels every resource of one server carries (`labels/2`)."
  @type labels :: %{String.t() => String.t()}

  @typedoc """
  One type as the provider sells it: its shape, whether it is x86 and still
  sold, the places it is in stock now and its monthly price in each, gross
  as the account is billed, in ten-thousandths of the currency's unit.
  """
  @type server_type :: %{
          name: String.t(),
          description: String.t(),
          cores: integer(),
          memory_gb: number() | nil,
          disk_gb: integer(),
          x86: boolean(),
          sold: boolean(),
          dedicated: boolean(),
          stock: [String.t()],
          monthly: %{String.t() => non_neg_integer()}
        }

  @typedoc "What the account can order now (`catalog/2`)."
  @type catalog :: %{
          currency: String.t(),
          locations: [%{id: String.t(), city: String.t(), country: String.t()}],
          types: [server_type()],
          ipv4_monthly: %{String.t() => non_neg_integer()}
        }

  @typedoc "The server `create_server/3` asks for."
  @type server_spec :: %{
          name: String.t(),
          type: String.t(),
          location: String.t(),
          image: String.t(),
          firewall: id(),
          labels: labels(),
          user_data: String.t()
        }

  @typedoc """
  An action a write started, as `action/3` reads it: `step` names what it
  does (create, start, delete, power on, reset), `message` the provider's
  own words when it ended in `:error`.
  """
  @type action :: %{
          id: String.t(),
          status: :running | :success | :error,
          step: :create | :start | :delete | :power_on | :reset | :other,
          message: String.t() | nil
        }

  @typedoc "A created server, as `create_server/3` answers it: its facts and its actions."
  @type created :: %{
          id: id(),
          ipv4: String.t() | nil,
          created_at: DateTime.t() | nil,
          primary_ips: [Ledger.primary_ip()],
          actions: [action()]
        }

  @typedoc """
  A resource `get/4` or `find/4` answers: its id, and for a server its power,
  its IPv4 address, when it was created and its primary addresses.
  """
  @type resource :: %{
          required(:id) => id(),
          optional(:power) => String.t() | nil,
          optional(:ipv4) => String.t() | nil,
          optional(:created_at) => DateTime.t() | nil,
          optional(:primary_ips) => [Ledger.primary_ip()],
          optional(atom()) => term()
        }

  @typedoc """
  A provider's refusal, the closed set its primitives answer: the shared
  kinds, the kinds the driver reads, and `{:unknown, error}` for a write
  whose outcome is not known.
  """
  @type error ::
          :unauthorized
          | :read_only_token
          | :account_limit
          | {:rate_limited, integer() | nil}
          | {:unreachable, String.t()}
          | {:other, String.t()}
          | :not_found
          | :in_use
          | :no_capacity
          | :no_image
          | {:unknown, error()}

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

  @type step :: :create | :start | :delete | :power_on | :reset | :other

  @type reason ::
          :unauthorized
          | :read_only_token
          | :account_limit
          | {:rate_limited, integer() | nil}
          | {:unreachable, String.t()}
          | {:other, String.t()}
          | :not_found
          | :resource_in_use
          | :no_capacity
          | :no_image
          | :other_project
          | {:unavailable, capacity()}
          | {:ineligible_type, String.t()}
          | {:action_failed, step(), String.t()}
          | {:action_timeout, step()}
          | :token_invalid
          | :token_refused
          | :token_replaced
          | {:code_unavailable, String.t()}
          | :user_data_too_large
          | :invalid_code
          | :interrupted
          | {:interrupted, String.t()}
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
  What a create asks for: the type and location (`Driver.options/3` names
  them), the profile the server is named and labelled by, and the monthly
  price and currency of the offer chosen (`total_monthly`, `currency`), which
  the server is written with.
  """
  @type request :: %{
          required(:type) => String.t(),
          required(:location) => String.t(),
          required(:profile) => String.t(),
          optional(:total_monthly) => String.t() | nil,
          optional(:currency) => String.t() | nil
        }

  @typedoc """
  The seams: the driver's own (`:now`, a 0-arity clock; `:sleep`, the pause
  between two polls; `:max_polls`; `:report`, the job's phase reporter;
  `:open_code`, a 0-arity function answering a fresh provisioned enrollment
  code; `:withdraw_code`, closing that window when its server will not
  exist; `:running?`), and the provider's own (such as `:req_options`, a
  test's plug), which the driver passes to every primitive as they are.
  """
  @type opts :: keyword()

  @callback id() :: String.t()
  @callback display() :: display()
  @callback type_name(String.t()) :: String.t()
  @callback max_user_data() :: pos_integer()
  @callback check_token(String.t(), opts()) ::
              {:ok, %{other_servers: boolean()}} | {:error, error()}
  @callback catalog(String.t(), opts()) :: {:ok, catalog()} | {:error, error()}
  @callback server_type(String.t(), String.t(), opts()) ::
              {:ok, %{type: server_type() | nil, cities: %{String.t() => String.t()}}}
              | {:error, error()}
  @callback system_image(String.t(), opts()) :: {:ok, String.t()} | {:error, error()}
  @callback create_firewall(String.t(), %{name: String.t(), labels: labels()}, opts()) ::
              {:ok, id()} | {:error, error()}
  @callback create_server(String.t(), server_spec(), opts()) ::
              {:ok, created()} | {:error, error()}
  @callback power(String.t(), id(), :on | :reset, opts()) :: {:ok, action()} | {:error, error()}
  @callback action(String.t(), String.t(), opts()) :: {:ok, action()} | {:error, error()}
  @callback get(String.t(), kind(), id(), opts()) :: {:ok, resource()} | {:error, error()}
  @callback find(String.t(), :server | :firewall, labels(), opts()) ::
              {:ok, resource() | nil} | {:error, error()}
  @callback delete(String.t(), kind(), id(), opts()) :: {:ok, action() | nil} | {:error, error()}

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
  def cities(provider), do: provider.display().locations |> Enum.map(& &1.city) |> listed()

  defp listed([city]), do: city
  defp listed(cities), do: Enum.join(Enum.drop(cities, -1), ", ") <> " or " <> List.last(cities)

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

  @doc "The labels every resource of the server named for `profile` and `ref` carries."
  @spec labels(String.t(), String.t()) :: labels()
  def labels(profile, ref) when is_binary(profile) and is_binary(ref),
    do: %{"fermix" => "always-on", "fermix-profile" => name_part(profile), "fermix-ref" => ref}

  @doc """
  A provider's own message as plain words a sentence can carry: a backtick
  reads as a quote, and it ends as a sentence does.
  """
  @spec plain(String.t()) :: String.t()
  def plain(message) when is_binary(message) do
    plain = String.replace(message, "`", "'")
    if String.ends_with?(plain, [".", "?", "!"]), do: plain, else: plain <> "."
  end

  @doc "The word the ledger keeps for why a create stopped."
  @spec failure_word(reason()) :: String.t()
  def failure_word({:old_server, reason}), do: failure_word(reason)
  def failure_word({:action_failed, _step, _message}), do: "action_failed"
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

  defp sentence(:token_replaced, _words),
    do: "The new token works, so try again."

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

  defp sentence({:ineligible_type, type}, words),
    do:
      "Fermix creates only a server type #{words.name} still sells with at least 4 GB on " <>
        "x86, and #{type} is not one."

  defp sentence({:action_failed, step, message}, words),
    do: "#{words.name} could not finish #{doing(step)}: #{plain(message)}"

  defp sentence({:action_timeout, step}, words),
    do:
      "#{words.name} had not finished #{doing(step)} after five minutes; Always On checks " <>
        "again when it opens."

  defp sentence(:no_image, words),
    do: "#{words.name} offers no Debian 13 image right now, so Fermix created no server."

  defp sentence(:no_capacity, words),
    do: "#{words.name} has no room for that right now, so try again in a few minutes."

  defp sentence(reason, words) when reason in [:not_found, :resource_in_use],
    do: "#{words.name} no longer has what Fermix created there, so open Always On again."

  defp sentence({:code_unavailable, sentence}, _words), do: sentence

  defp sentence(:user_data_too_large, words),
    do: "The setup Fermix puts on a new server is larger than #{words.name} takes."

  defp sentence(:invalid_code, _words),
    do: "Fermix made an enrollment code it could not put on the server, so start again."

  defp sentence(:interrupted, _words),
    do: "Fermix stopped before your server was created, so start again."

  defp sentence({:interrupted, "create"}, words), do: sentence(:interrupted, words)

  defp sentence({:interrupted, "delete"}, _words),
    do: "Fermix stopped before your server was deleted, so delete it again."

  defp sentence({:interrupted, "power_on"}, _words),
    do: "Fermix stopped before your server was turned on, so turn it on again."

  defp sentence({:interrupted, "power_reset"}, _words),
    do: "Fermix stopped before your server restarted, so restart it again."

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

  defp doing(:create), do: "creating your server"
  defp doing(:start), do: "starting your server"
  defp doing(:delete), do: "deleting your server"
  defp doing(:power_on), do: "turning your server on"
  defp doing(:reset), do: "restarting your server"
  defp doing(:other), do: "what Fermix asked of it"
end
