defmodule FermixCore.Cues.Mandates do
  @moduledoc """
  The owner's mandates (M60 §10.1, PLAN §1 decision 1): what each
  `[fermix_core.cues.mandates.<name>]` section grants, and whether it may act.

  `Cues.Config.mandates/0` parses the sections; this module turns each into a
  `%Mandates{}` and runs the load checks, every time it is asked, so a changed
  setting or file is seen at the next question (the switches are read at every
  mandate call, design §10.1). A mandate that fails a check is inactive, with
  the check's sentence as its reason (the setup page shows it):

    * `tools` names at least one tool, and every name in `tools` and
      `read_tools` is an `http`-rail plugin tool (a declarative `request`
      template, so its scheme and host are the manifest's); an MCP tool, a
      command or `web_fetch` is refused; a tool whose manifest asks for
      confirmation on every call (`access_sensitive`) is no reader, so it is
      refused in `read_tools`;
    * the job exists and runs on cues (B43); one job has at most one mandate;
    * `approve` mode needs somewhere to ask the owner (C55, the reach rule of
      M60 app surface §3.7): a Telegram, Signal, WhatsApp or iMessage chat with
      the owner that can carry a confirmation (`OwnerInbox.dm_origin/1`), or
      the Fermix app (`app_surface?/1`);
    * `auto` mode needs a validator or `pin_args` (decision 1);
    * `interpreter` is a Python (`python`, `python3` or `python3.N` by name),
      since Fermix isolates it with `-I`; a validator in another language
      runs directly;
    * `idempotency_arg` is an argument of at least one of `tools`, and every
      `pin_args` key an argument of each of them;
    * a validator (and its interpreter, symlinks resolved) is an absolute path
      to a regular file that, like every directory above it, is owned by
      another user than the daemon's and is writable by neither group nor
      others; a path under the daemon user's home always fails (§10.4).

  `unchecked/2` reads one section as it is now without the checks, for what a
  mandate call reads live (its switch, its pin); `Cues.MandateGate` keeps the
  checks' verdict for the rest of the run.

  Seams (opts): `:config` (the `[fermix_core.cues]` keyword), `:repo`,
  `:get_job` (`fn job_id -> {:ok, job} | {:error, _}`), `:plugin_tool`
  (`fn name -> {:ok, %{plugin: name, tool: manifest}} | :error`),
  `:jobs_config` and `:configured_owners` (the owner inbox), `:app_surface?`
  (whether this engine has an app to ask the owner in) or `:host_facts` (what
  `FermixCore.HostFacts` read at boot), and for the
  ownership check `:stat` (`fn path -> {:ok, %{uid:, mode:, type:}} | {:error,
  _}`), `:resolve` (`fn path -> {:ok, real_path} | {:error, _}`), `:daemon_uid`
  and `:home`.
  """

  alias FermixCore.BuildInfo
  alias FermixCore.Capabilities.AccessGate
  alias FermixCore.Capabilities.Capability
  alias FermixCore.Cues.Config
  alias FermixCore.Delivery.OwnerInbox
  alias FermixCore.Jobs.Registry, as: JobsRegistry
  alias FermixCore.Memory.Repo
  alias FermixCore.Plugins.Registry, as: PluginRegistry
  alias FermixCore.Sandbox.PathPolicy

  # An interpreter Fermix can isolate with `-I`: a Python, by its file name.
  @python_name ~r/\Apython(3(\.\d+)?)?\z/

  @approve_inbox_sentence "Approve mode needs somewhere to ask you: a Telegram, Signal, " <>
                            "WhatsApp or iMessage chat with you, or the Fermix app."
  @auto_sentence "Auto mode needs a validator or pinned arguments; use approve mode otherwise."

  @enforce_keys [:name, :job, :mode, :tools, :read_tools]
  defstruct [
    :name,
    :job,
    :job_name,
    :mode,
    :approve_within_s,
    :max_cue_age_s,
    :validator,
    :interpreter,
    :idempotency_arg,
    enabled?: true,
    tools: [],
    read_tools: [],
    validator_env: [],
    unpinned: [],
    pin_args: %{},
    status: :active
  ]

  @typedoc """
  `:active` passed every load check; `{:inactive, sentence}` failed one;
  `:unchecked` was read by `unchecked/2`, which runs none (never active).
  """
  @type status :: :active | :unchecked | {:inactive, String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          job: String.t(),
          job_name: String.t() | nil,
          enabled?: boolean(),
          mode: :approve | :auto,
          approve_within_s: pos_integer(),
          tools: [String.t()],
          read_tools: [String.t()],
          max_cue_age_s: non_neg_integer(),
          validator: String.t() | nil,
          interpreter: String.t() | nil,
          validator_env: [String.t()],
          idempotency_arg: String.t() | nil,
          unpinned: [String.t()],
          pin_args: map(),
          status: status()
        }

  @doc "The sentence a mandate in approve mode is refused with when Fermix can ask the owner nowhere."
  @spec approve_inbox_sentence() :: String.t()
  def approve_inbox_sentence, do: @approve_inbox_sentence

  @doc """
  Whether this engine has an app to ask the owner in (the reach rule): the Mac
  app's own engine, or the Linux desktop app when it was installed as Fermix
  started. The Linux app is a Flatpak beside the host's package, so a package
  build alone says nothing about it (a headless server would hold every
  proposal unseen); `FermixCore.HostFacts` reads its entry at boot, and an app
  installed later counts at the next restart. A paired phone is not one until
  its wire carries proposals. Seams: `:app_surface?`, `:host_facts`.
  """
  @spec app_surface?(keyword()) :: boolean()
  def app_surface?(opts \\ []) when is_list(opts) do
    case Keyword.fetch(opts, :app_surface?) do
      {:ok, app?} when is_boolean(app?) ->
        app?

      :error ->
        BuildInfo.app_engine?() or linux_app?(Keyword.get_lazy(opts, :host_facts, &host_facts/0))
    end
  end

  defp linux_app?(%{linux_app: true}), do: true
  defp linux_app?(_facts), do: false

  # The facts are read as the daemon's tree starts; a process that started no
  # tree (a CLI verb) has none, and knows of no app.
  defp host_facts do
    case Application.fetch_env(:fermix_core, :host_facts) do
      {:ok, facts} -> facts
      :error -> %{}
    end
  end

  @doc "Every configured mandate, sorted by name, each with its load-check status."
  @spec load(keyword()) :: [t()]
  def load(opts \\ []) when is_list(opts) do
    case opts |> cues_config() |> Config.mandates() do
      [] ->
        []

      sections ->
        shared = shared_jobs(sections)
        opts = Keyword.put_new_lazy(opts, :plugin_tool, &registry_lookup/0)
        Enum.map(sections, &checked(&1, shared, opts))
    end
  end

  @doc "One mandate by name, checked, or `:error` when no section names it."
  @spec get(String.t(), keyword()) :: {:ok, t()} | :error
  def get(name, opts \\ []) when is_binary(name) and is_list(opts) do
    case Enum.find(load(opts), &(&1.name == name)) do
      nil -> :error
      mandate -> {:ok, mandate}
    end
  end

  @doc """
  Mandate `name` as its section reads now, with no load check run (status
  `:unchecked`, never active), or `:error` when no section names it. For the
  parts a mandate call reads at every call: the switch and what the pin covers.
  """
  @spec unchecked(String.t(), keyword()) :: {:ok, t()} | :error
  def unchecked(name, opts \\ []) when is_binary(name) and is_list(opts) do
    case section(name, opts) do
      {:ok, section} -> {:ok, %{from_section(section) | status: :unchecked}}
      :error -> :error
    end
  end

  @doc """
  The active mandate a cue run of `job_id` acts under, or nil. An inactive
  mandate grants a run nothing: its tools are not offered.
  """
  @spec for_job(String.t(), keyword()) :: t() | nil
  def for_job(job_id, opts \\ []) when is_binary(job_id) and is_list(opts) do
    sections = opts |> cues_config() |> Config.mandates()

    if Enum.any?(sections, &(&1.job == job_id)) do
      opts |> load() |> Enum.find(&(&1.job == job_id and active?(&1)))
    end
  end

  @doc "The names of the mandates whose section names `job_id` (no checks)."
  @spec names_for_job(String.t(), keyword()) :: [String.t()]
  def names_for_job(job_id, opts \\ []) when is_binary(job_id) and is_list(opts) do
    opts
    |> cues_config()
    |> Config.mandates()
    |> Enum.filter(&(&1.job == job_id))
    |> Enum.map(& &1.name)
  end

  @doc "Whether the mandate passed every load check."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: :active}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "A mandate's raw section, with no checks (for reads on every model turn)."
  @spec section(String.t(), keyword()) :: {:ok, Config.mandate()} | :error
  def section(name, opts \\ []) when is_binary(name) and is_list(opts) do
    case opts |> cues_config() |> Config.mandates() |> Enum.find(&(&1.name == name)) do
      nil -> :error
      section -> {:ok, section}
    end
  end

  @doc """
  For `update_job`: a job a mandate names changes only on the owner's consent
  turn (design §10.4, S6).
  """
  @spec check_update_consent(String.t(), map(), keyword()) :: :ok | {:error, String.t()}
  def check_update_consent(job_id, context, opts \\ [])
      when is_binary(job_id) and is_map(context) and is_list(opts) do
    case names_for_job(job_id, opts) do
      [] ->
        :ok

      [name | _rest] ->
        if AccessGate.owner_consent_turn?(context),
          do: :ok,
          else:
            {:error,
             "Mandate #{name} acts for this job; change it from a private chat with Fermix, " <>
               "in a turn that has read no outside text."}
    end
  end

  @doc """
  The schema the model sees for a mandate tool in a cue run of its job: the
  mandate's `idempotency_arg` is removed, because Fermix sets it (C39). Every
  other capability, and every other run, keeps its schema.
  """
  @spec hide_set_arguments(Capability.t(), map()) :: Capability.t()
  def hide_set_arguments(
        %Capability{name: name} = capability,
        %{trigger: "cue", cue_mandate: mandate} = context
      )
      when is_binary(mandate) do
    case section(mandate, Map.get(context, :cue_mandate_opts, [])) do
      {:ok, %{idempotency_arg: arg, tools: tools}} when is_binary(arg) ->
        if name in tools, do: drop_property(capability, arg), else: capability

      _no_arg_or_no_section ->
        capability
    end
  end

  def hide_set_arguments(%Capability{} = capability, context) when is_map(context),
    do: capability

  @doc """
  Why a call of `tool` with `args` is outside `mandate` as it reads now (the
  tool is not one of its `tools`, or a `pin_args` entry does not have its
  value), as the sentence a refusal gives; nil when it is inside. One rule for
  the gate's call and a proposal's confirm.
  """
  @spec outside_grant(t(), String.t(), map()) :: String.t() | nil
  def outside_grant(%__MODULE__{tools: tools, pin_args: pins}, tool, args)
      when is_binary(tool) and is_map(args) do
    if tool in tools,
      do: unpinned_arg(pins, args),
      else: "#{tool} is no longer one of the mandate's tools"
  end

  defp unpinned_arg(pins, args) do
    case Enum.find(pins, fn {key, value} -> Map.fetch(args, key) != {:ok, value} end) do
      nil -> nil
      {key, value} -> "the argument #{key} must be #{inspect(value)}, as the mandate pins it"
    end
  end

  @doc """
  The manifest of the `http`-rail plugin tool `name` (a declarative `request`
  template), `:error` for any other kind of tool, or the plugin catalog's own
  error when it cannot be read.
  """
  @spec http_tool(String.t(), keyword()) ::
          {:ok, %{plugin: String.t(), tool: map()}} | :error | {:error, term()}
  def http_tool(name, opts \\ []) when is_binary(name) and is_list(opts) do
    lookup = Keyword.get_lazy(opts, :plugin_tool, &registry_lookup/0)
    lookup.(name)
  end

  # --- load checks ---------------------------------------------------------------------

  defp checked(section, shared, opts) do
    mandate = from_section(section)
    {job_status, job_name} = check_job(mandate, opts)

    status =
      first_failure([
        fn -> check_shared(mandate, shared) end,
        fn -> check_tools(mandate, opts) end,
        fn -> check_read_tools(mandate, opts) end,
        fn -> job_status end,
        fn -> check_mode(mandate, opts) end,
        fn -> check_validator_fields(mandate) end,
        fn -> check_interpreter(mandate) end,
        fn -> check_idempotency_arg(mandate, opts) end,
        fn -> check_pin_args(mandate, opts) end,
        fn -> check_validator_files(mandate, opts) end
      ])

    %{mandate | status: status, job_name: job_name}
  end

  defp first_failure(checks) do
    Enum.reduce_while(checks, :active, fn check, :active ->
      case check.() do
        :ok -> {:cont, :active}
        {:error, sentence} -> {:halt, {:inactive, sentence}}
      end
    end)
  end

  defp from_section(section) do
    struct!(__MODULE__, %{
      name: section.name,
      job: section.job,
      enabled?: section.enabled?,
      mode: section.mode,
      approve_within_s: section.approve_within_s,
      tools: section.tools,
      read_tools: section.read_tools,
      max_cue_age_s: section.max_cue_age_s,
      validator: section.validator,
      interpreter: section.interpreter,
      validator_env: section.validator_env,
      idempotency_arg: section.idempotency_arg,
      unpinned: section.unpinned,
      pin_args: section.pin_args || %{}
    })
  end

  defp shared_jobs(sections) do
    sections
    |> Enum.group_by(& &1.job, & &1.name)
    |> Enum.filter(fn {_job, names} -> length(names) > 1 end)
    |> Map.new()
  end

  defp check_shared(mandate, shared) do
    case Map.fetch(shared, mandate.job) do
      {:ok, names} ->
        {:error,
         "Mandates #{Enum.join(names, " and ")} name the same job; a job has at most one mandate."}

      :error ->
        :ok
    end
  end

  defp check_tools(%{tools: []} = mandate, _opts),
    do: {:error, "Mandate #{mandate.name} names no tools; list its action tools in tools."}

  defp check_tools(mandate, opts) do
    (mandate.tools ++ mandate.read_tools)
    |> Enum.map(&{&1, http_tool(&1, opts)})
    |> Enum.find(fn {_tool, found} -> not match?({:ok, _manifest}, found) end)
    |> tool_failure()
  end

  defp tool_failure(nil), do: :ok

  defp tool_failure({tool, :error}) do
    {:error,
     "#{tool} is not an http plugin tool; a mandate names only http plugin tools (no MCP " <>
       "tool, command or web_fetch)."}
  end

  defp tool_failure({_tool, {:error, reason}}),
    do: {:error, "The plugin catalog could not be read: #{inspect(reason)}."}

  # A tool that asks for confirmation on every call changes something (the
  # registry refuses the flag on a read-only tool), so it is never a reader:
  # lane 0 would refuse each call in a cue run anyway.
  defp check_read_tools(mandate, opts) do
    case Enum.find(mandate.read_tools, &access_sensitive?(&1, opts)) do
      nil ->
        :ok

      tool ->
        {:error,
         "#{tool} asks for confirmation on every call; list it under tools or leave it out."}
    end
  end

  defp access_sensitive?(tool_name, opts) do
    case http_tool(tool_name, opts) do
      {:ok, %{tool: tool}} -> Map.get(tool, "access_sensitive") == true
      _not_found -> false
    end
  end

  defp check_job(mandate, opts) do
    case get_job(mandate.job, opts) do
      {:ok, job} ->
        {cue_job(job, mandate), Map.get(job, :name)}

      {:error, :not_found} ->
        {{:error, "Job #{mandate.job} does not exist."}, nil}

      {:error, reason} ->
        {{:error, "Job #{mandate.job} could not be read: #{inspect(reason)}"}, nil}
    end
  end

  defp cue_job(job, mandate) do
    if JobsRegistry.cue_job?(job),
      do: :ok,
      else:
        {:error,
         "Job #{mandate.job} runs on a schedule; a mandate names a job that runs on cues."}
  end

  defp check_mode(%{mode: :approve}, opts) do
    if app_surface?(opts) or owner_chat?(opts), do: :ok, else: {:error, @approve_inbox_sentence}
  end

  defp check_mode(%{mode: :auto, validator: nil, pin_args: pins}, _opts) when map_size(pins) == 0,
    do: {:error, @auto_sentence}

  defp check_mode(%{mode: :auto}, _opts), do: :ok

  defp check_validator_fields(%{validator: nil, interpreter: interpreter, validator_env: env})
       when not is_nil(interpreter) or env != [],
       do: {:error, "interpreter and validator_env need a validator."}

  defp check_validator_fields(_mandate), do: :ok

  defp check_interpreter(%{interpreter: nil}), do: :ok

  defp check_interpreter(%{interpreter: interpreter}) do
    if Regex.match?(@python_name, Path.basename(interpreter)),
      do: :ok,
      else:
        {:error,
         "The interpreter #{interpreter} is not a Python (python, python3 or python3.N); a " <>
           "validator in another language runs directly, with no interpreter."}
  end

  defp check_idempotency_arg(%{idempotency_arg: nil}, _opts), do: :ok

  defp check_idempotency_arg(%{idempotency_arg: arg, tools: tools}, opts) do
    if Enum.any?(tools, &takes_argument?(&1, arg, opts)),
      do: :ok,
      else: {:error, "idempotency_arg #{arg} is not an argument of any of the mandate's tools."}
  end

  # Every call must carry each pinned argument, so a key one tool does not
  # declare would refuse every call to it; it is refused here instead.
  defp check_pin_args(%{pin_args: pins, tools: tools}, opts) do
    missing =
      for key <- pins |> Map.keys() |> Enum.sort(),
          tool <- tools,
          not takes_argument?(tool, key, opts),
          do: {key, tool}

    case missing do
      [] ->
        :ok

      [{key, tool} | _rest] ->
        {:error,
         "pin_args #{key} is not an argument of #{tool}; every pinned argument must be an " <>
           "argument of each tool in tools."}
    end
  end

  defp takes_argument?(tool_name, arg, opts) do
    case http_tool(tool_name, opts) do
      {:ok, %{tool: tool}} -> tool |> properties() |> Map.has_key?(arg)
      _not_found -> false
    end
  end

  defp check_validator_files(%{validator: nil}, _opts), do: :ok

  defp check_validator_files(mandate, opts) do
    with :ok <- check_owned(mandate.validator, "validator", opts) do
      if mandate.interpreter, do: check_owned(mandate.interpreter, "interpreter", opts), else: :ok
    end
  end

  # The file itself (symlinks resolved), then every directory above it.
  defp check_owned(path, label, opts) do
    with :ok <- absolute(path, label),
         {:ok, real} <- resolve(path, label, opts),
         :ok <- outside_home(real, label, opts),
         :ok <- owned_file(real, label, opts) do
      real |> parents() |> Enum.reduce_while(:ok, &owned_dir(&1, &2, label, opts))
    end
  end

  defp absolute(path, label) do
    if Path.type(path) == :absolute,
      do: :ok,
      else: {:error, "The #{label} #{path} must be an absolute path."}
  end

  defp resolve(path, label, opts) do
    resolver = Keyword.get(opts, :resolve, &PathPolicy.resolve_links/1)

    case resolver.(path) do
      {:ok, real} -> {:ok, real}
      {:error, reason} -> {:error, "The #{label} #{path} cannot be read: #{inspect(reason)}."}
    end
  end

  defp outside_home(real, label, opts) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)

    if real == home or String.starts_with?(real, String.trim_trailing(home, "/") <> "/") do
      {:error,
       "The #{label} #{real} is under the daemon user's home, which that user can change; " <>
         "install it outside, owned by root (for example with sudo install -o root -m 0755)."}
    else
      :ok
    end
  end

  defp owned_file(real, label, opts) do
    case stat(real, opts) do
      {:ok, %{type: :regular} = info} -> owner_check(info, real, label, opts)
      {:ok, _not_a_file} -> {:error, "The #{label} #{real} is not a regular file."}
      {:error, reason} -> {:error, "The #{label} #{real} cannot be read: #{inspect(reason)}."}
    end
  end

  defp owned_dir(dir, :ok, label, opts) do
    result =
      case stat(dir, opts) do
        {:ok, info} -> owner_check(info, dir, label, opts)
        {:error, reason} -> {:error, "#{dir} cannot be read: #{inspect(reason)}."}
      end

    if result == :ok, do: {:cont, :ok}, else: {:halt, result}
  end

  defp owner_check(%{uid: uid, mode: mode}, path, label, opts) do
    cond do
      uid == daemon_uid(opts) ->
        {:error,
         "The #{label} must be owned by another user than Fermix's (root): #{path} is owned " <>
           "by the daemon's user. Install it with sudo install -o root -m 0755."}

      Bitwise.band(mode, 0o022) != 0 ->
        {:error,
         "The #{label} must not be writable by group or others: #{path} is. Install it with " <>
           "sudo install -o root -m 0755."}

      true ->
        :ok
    end
  end

  defp parents(path) do
    path
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reverse()
  end

  defp stat(path, opts) do
    case Keyword.get(opts, :stat) do
      fun when is_function(fun, 1) -> fun.(path)
      nil -> file_stat(path)
    end
  end

  defp file_stat(path) do
    case File.stat(path) do
      {:ok, %File.Stat{uid: uid, mode: mode, type: type}} ->
        {:ok, %{uid: uid, mode: mode, type: type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The daemon's user owns its home directory: no uid call needed.
  defp daemon_uid(opts) do
    Keyword.get_lazy(opts, :daemon_uid, fn ->
      %File.Stat{uid: uid} = File.stat!(System.user_home!())
      uid
    end)
  end

  # --- lookups -------------------------------------------------------------------------

  defp cues_config(opts),
    do: Keyword.get_lazy(opts, :config, fn -> Application.get_env(:fermix_core, :cues, []) end)

  defp get_job(job_id, opts) do
    case Keyword.get(opts, :get_job) do
      fun when is_function(fun, 1) -> fun.(job_id)
      nil -> JobsRegistry.get_job(job_id, repo: Keyword.get(opts, :repo, Repo))
    end
  end

  defp owner_inbox(opts),
    do: OwnerInbox.resolve(Keyword.take(opts, [:jobs_config, :configured_owners]))

  defp owner_chat?(opts) do
    with {:ok, inbox} <- owner_inbox(opts),
         {:ok, _origin} <- OwnerInbox.dm_origin(inbox) do
      true
    else
      _other_or_none -> false
    end
  end

  # The plugin catalog, read once per load: every `http`-rail tool by name.
  defp registry_lookup do
    case PluginRegistry.list() do
      {:ok, plugins} ->
        tools = plugins |> Enum.flat_map(&http_tools/1) |> Map.new()
        fn name -> Map.fetch(tools, name) end

      {:error, reason} ->
        fn _name -> {:error, reason} end
    end
  end

  defp http_tools(plugin) do
    for %{"name" => name, "request" => request} = tool <- plugin.tools,
        is_map(request) and Map.get(tool, "rail") != "mcp",
        do: {name, %{plugin: plugin.name, tool: tool}}
  end

  @doc false
  @spec properties(map()) :: map()
  def properties(tool) when is_map(tool) do
    tool
    |> Map.get("parameters", %{})
    |> Map.get("properties", %{})
  end

  defp drop_property(%Capability{parameters: parameters} = capability, arg) do
    properties = fetch_either(parameters, "properties", :properties)
    required = fetch_either(parameters, "required", :required)

    parameters =
      parameters
      |> put_either("properties", :properties, drop_key(properties, arg))
      |> put_either("required", :required, drop_name(required, arg))

    %{capability | parameters: parameters}
  end

  defp fetch_either(map, string_key, atom_key),
    do: Map.get(map, string_key, Map.get(map, atom_key))

  defp put_either(map, _string_key, _atom_key, nil), do: map

  defp put_either(map, string_key, atom_key, value) do
    if Map.has_key?(map, atom_key),
      do: Map.put(map, atom_key, value),
      else: Map.put(map, string_key, value)
  end

  defp drop_key(nil, _arg), do: nil

  # A schema may be string- or atom-keyed; the argument is matched by its text.
  defp drop_key(properties, arg) when is_map(properties),
    do: Map.reject(properties, fn {key, _spec} -> to_string(key) == arg end)

  defp drop_name(nil, _arg), do: nil

  defp drop_name(required, arg) when is_list(required),
    do: Enum.reject(required, &(to_string(&1) == arg))
end
