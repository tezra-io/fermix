defmodule FermixCore.Home.Provision do
  @moduledoc """
  A host Fermix creates an Always On server on (M75 lean v1 §4.3, L1, L2):
  one behaviour in the engine, so both apps and the CLI share one
  implementation over management (`FermixCore.Management.Provision`,
  `home.provision.*`). `Provision.Hetzner` is the one host in v1.

  A host keeps its token and what it created in one ledger file
  (`Provision.Ledger`, `device/provision/<host>.json`), written before each
  call that creates or deletes and updated after it. A host's callbacks:

    * `check_token/2`: reads the project, so a token the host refuses is
      named at once; answers whether the project holds servers Fermix did not
      create (Details says "Fermix only touches what it creates").
    * `reaches/3`: whether a new token is of the project the ledger's server
      (or firewall) is in, so a token for another project never replaces the
      one that reaches what Fermix created.
    * `options/2`: the orderable types per location with their monthly prices
      as the account is billed, and the L2 recommendation, read live.
    * `create/3`: the firewall with no inbound rule first (a read-only token
      fails there, before anything costs money), then the server with the
      first boot (`Provision.FirstBoot`) and a fresh 24-hour enrollment code
      inside, each write's action polled with a bound.
    * `power/3`: turns the server on, or restarts it.
    * `reconcile/2`: reads what the ledger names from the host: a resource
      deleted outside Fermix is marked gone, a server's power is recorded, and
      a create whose answer was lost is found again by its labels.
    * `delete/2`: the server, then its primary addresses unless they went with
      it, then the firewall.
    * `delete_replaced/2`: the same, in the same order, for the server a
      replace retired (`Ledger.retired/1`), never one that still holds the
      home; the ledger then keeps that the replace is done.

  Every refusal is a reason `error_sentence/1` turns into one sentence in
  the daemon's words, and `failure_word/1` into the word the ledger keeps.

  Names and labels (`server_name/2`, `labels/2`): a server is named
  `fermix-<profile>-<ref>`, `ref` four hex digits from the ledger, so a new
  server never collides with one it replaces, and every resource carries
  `fermix=always-on`, `fermix-profile=<profile>` and `fermix-ref=<ref>`, the
  profile sanitised to the host's label rules.
  """

  alias FermixCore.Home.Provision.Ledger

  @type reason ::
          :unauthorized
          | :token_invalid
          | :token_refused
          | :forbidden
          | :account_limit
          | :not_found
          | :resource_in_use
          | {:unavailable, map()}
          | {:ineligible_type, String.t()}
          | {:rate_limited, integer() | nil}
          | {:unreachable, String.t()}
          | {:refused, pos_integer(), String.t(), String.t()}
          | {:action_failed, String.t(), String.t()}
          | {:action_timeout, String.t()}
          | {:code_unavailable, String.t()}
          | :user_data_too_large
          | :no_image
          | :too_many_types
          | :invalid_code
          | :interrupted
          | :no_token
          | :no_server
          | :server_exists
          | :nothing_to_delete
          | :not_primary
          | :other_project
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
          | {:code_refused, String.t()}
          | {:withdraw_refused, String.t()}
          | {:old_server, reason()}
          | {:ledger, term()}

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

  @callback host() :: String.t()
  @doc """
  Whether `token` reaches what the ledger holds: one read, by id, of its
  server (or else its firewall) that is not gone; `{:error,
  :other_project}` when the host says it has no such thing for this token.
  Nothing standing is reached by any token.
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

  @max_profile_label 40

  @doc "The server's name for `profile` and the ledger's `ref`."
  @spec server_name(String.t(), String.t()) :: String.t()
  def server_name(profile, ref) when is_binary(profile) and is_binary(ref),
    do: "fermix-#{label_value(profile)}-#{ref}"

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

  @doc "The labels every resource of `ref` carries."
  @spec labels(String.t(), String.t()) :: %{String.t() => String.t()}
  def labels(profile, ref) when is_binary(profile) and is_binary(ref),
    do: %{"fermix" => "always-on", "fermix-profile" => label_value(profile), "fermix-ref" => ref}

  @doc """
  `profile` as a label value and a host name part: lower-case letters and
  digits, runs of anything else one hyphen, at most #{@max_profile_label}
  characters, never starting or ending with a hyphen. A profile with nothing
  left is named by its digest (`p` and eight hex digits).
  """
  @spec label_value(String.t()) :: String.t()
  def label_value(profile) when is_binary(profile) do
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
  def failure_word({:refused, _status, _code, _message}), do: "refused"
  def failure_word({:action_failed, _command, _message}), do: "action_failed"
  def failure_word(:forbidden), do: "read_only_token"
  def failure_word(reason) when is_atom(reason), do: Atom.to_string(reason)

  @doc """
  One sentence for `reason`, in the daemon's words (and the host's own where
  it has some): plain words, with no code or HTTP status, since the summary
  prints a create's failure as it is.
  """
  @spec error_sentence(reason()) :: String.t()
  def error_sentence(:token_invalid),
    do:
      "Hetzner does not accept this token, so paste a Read & Write API token from the " <>
        "Hetzner project you made for Fermix."

  def error_sentence(reason) when reason in [:unauthorized, :token_refused],
    do: "Hetzner no longer accepts Fermix's token."

  def error_sentence(:forbidden),
    do:
      "This token can only read, so Fermix created nothing; paste a Read & Write API token " <>
        "from your Hetzner project."

  def error_sentence(:account_limit), do: "Hetzner limits new servers on this account."

  def error_sentence({:unavailable, %{city: city, description: type, next_city: nil}}),
    do: "No location Fermix offers has a #{type} right now, #{city} included."

  def error_sentence({:unavailable, %{city: city, description: type}}),
    do: "#{city} has no #{type} right now."

  def error_sentence({:ineligible_type, type}),
    do:
      "Fermix creates only a server type Hetzner still sells with at least 4 GB on x86, " <>
        "and #{type} is not one."

  def error_sentence({:rate_limited, _reset}),
    do: "Hetzner is limiting how often Fermix may ask, so try again in a few minutes."

  def error_sentence({:unreachable, _reason}),
    do: "Fermix could not reach Hetzner, so check this computer's connection and try again."

  def error_sentence({:refused, _status, _code, message}),
    do: "Hetzner refused the request: #{vendor(message)}"

  def error_sentence({:action_failed, command, message}),
    do: "Hetzner could not finish #{doing(command)}: #{vendor(message)}"

  def error_sentence({:action_timeout, command}),
    do:
      "Hetzner had not finished #{doing(command)} after five minutes; Always On checks " <>
        "again when it opens."

  def error_sentence({:code_unavailable, sentence}), do: sentence

  def error_sentence(:no_image),
    do: "Hetzner offers no Debian 13 image right now, so Fermix created no server."

  def error_sentence(:too_many_types),
    do: "Hetzner listed more server types than Fermix reads, so it offers none right now."

  def error_sentence(:user_data_too_large),
    do: "The setup Fermix puts on a new server is larger than Hetzner takes."

  def error_sentence(:invalid_code),
    do: "Fermix made an enrollment code it could not put on the server, so start again."

  def error_sentence(:interrupted),
    do: "Fermix stopped before your server was created, so start again."

  def error_sentence(:no_token), do: "Paste a Hetzner API token first."

  def error_sentence(:no_server),
    do: "Fermix has no server on Hetzner to turn on or restart."

  def error_sentence(:server_exists),
    do: "Your server already exists, so delete it before creating another."

  def error_sentence(:nothing_to_delete), do: "Fermix created nothing on Hetzner to delete."

  def error_sentence(:not_primary),
    do:
      "Fermix runs on your server now, so it creates no other one from here; to replace " <>
        "that server, get a code in Always On and use it on a Linux server of your own."

  def error_sentence(:other_project),
    do:
      "This token is for another Hetzner project than the server Fermix created, so paste " <>
        "a token from that project."

  def error_sentence(:live_home),
    do:
      "Your server runs Fermix now, so Fermix does not delete it; replace the server " <>
        "instead."

  def error_sentence(:move_under_way),
    do: "Fermix is moving to your server, so it is not deleted while the move runs."

  def error_sentence(:replace_only),
    do: "Fermix runs on your server now, so a new server from here can only replace it."

  def error_sentence(:nothing_to_replace),
    do: "Fermix runs on this computer, so there is no server to replace yet."

  def error_sentence(:replacement_exists),
    do: "Your new server already exists, so delete it before creating another."

  def error_sentence(:replace_moving),
    do: "Fermix is moving to your new server, so it creates no other one until the move is done."

  def error_sentence(:old_server_remains),
    do: "Your old server still exists, so delete it before replacing this one."

  def error_sentence(:replacement_gone),
    do: "Your new server was deleted in Hetzner, so replace the server again."

  def error_sentence(:no_link),
    do:
      "Fermix could not read how this computer reaches your server, so it created nothing; " <>
        "the daemon log says why."

  def error_sentence(:code_unreachable),
    do:
      "Fermix cannot reach your server to get a code for the new one, so try again once your " <>
        "server is back."

  def error_sentence(:withdraw_unreachable),
    do:
      "Fermix cannot reach your server to close the code it gave the new one, so try again " <>
        "once your server is back."

  def error_sentence({:code_refused, _code}),
    do: "Your server did not open a code for the new one."

  def error_sentence({:withdraw_refused, _code}),
    do: "Your server did not close the code it gave the new one."

  def error_sentence({:old_server, reason}),
    do: "Fermix could not delete your old server: #{error_sentence(reason)}"

  def error_sentence(reason) when reason in [:not_found, :resource_in_use],
    do: "Hetzner no longer has what Fermix created there, so open Always On again."

  def error_sentence({:ledger, _reason}),
    do: "Fermix could not keep its Hetzner file; the daemon log says why."

  defp doing("create_server"), do: "creating your server"
  defp doing("start_server"), do: "starting your server"
  defp doing("delete_server"), do: "deleting your server"
  defp doing("poweron_server"), do: "turning your server on"
  defp doing("reset_server"), do: "restarting your server"
  defp doing(_command), do: "what Fermix asked of it"

  # Hetzner's own message, as plain words the summary can print: a backtick
  # in it reads as a quote. Its code and HTTP status are in the log
  # (`Provision.Hetzner`), never in the sentence.
  defp vendor(message) do
    plain = String.replace(message, "`", "'")
    if String.ends_with?(plain, [".", "?", "!"]), do: plain, else: plain <> "."
  end
end
