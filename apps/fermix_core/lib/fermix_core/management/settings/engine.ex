defmodule FermixCore.Management.Settings.Engine do
  @moduledoc """
  The `engine` section (M75 §16): this computer's own place in Always On,
  under the `always_on` pane beside the snapshots. It is device-class
  (`Management.Placement`): a linked desktop answers it itself rather than
  forwarding it, because it describes and configures the machine it runs on.

  Two rows, both projections of `[fermix_core.engine]` (`Home.Role`):

    * `engine_role`, read-only: the role this engine booted in, with a
      sentence. It is never written from a settings surface: the move and
      `fermix home enroll` own it, and a role written here would take effect
      only at the next start, behind the owner's back.
    * `engine_executor`, a switch, published only in the device role, where
      it means something: whether the actions the primary asks of this
      computer run here (`Role.executor?/1`). It is read at every action, so
      a write applies at once, on this computer only.

  The booted role comes from `Role.recorded/0`; `:engine_role` in the
  options stands in for it (tests, and the router's own seam).
  """

  alias FermixCore.Home.Role
  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Setup.ConfigStore
  alias FermixCore.Setup.Wizard

  @section %{id: "engine", pane: "always_on", title: "This computer"}
  @answers [:executor]

  @role_info "The role changes only through a move, never from settings."
  @executor_footer "Notifications, web pages, files and commands the primary asks this " <>
                     "computer for."
  @executor_info "Every command still waits for your approval, and this computer's own " <>
                   "sandbox decides what may be read or run. The primary has its own switch " <>
                   "for this computer; an action runs only when both allow it."

  @doc "The one section this module owns."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: [@section]

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: section == @section.id

  @doc """
  The rows of the owned section for the role this engine booted in, or the
  record `opts[:engine_role]` names.
  """
  @spec rows(String.t(), Source.snapshot(), keyword()) :: [Row.t()]
  def rows("engine", snapshot, opts) when is_map(snapshot) and is_list(opts) do
    record = Keyword.get_lazy(opts, :engine_role, &Role.recorded/0)
    [role_row(record) | executor_rows(record, Source.core(snapshot, :engine))]
  end

  defp role_row(%{role: role} = record) when role in [:primary, :device, :candidate] do
    Row.new("engine_role", :choice, "This computer is",
      footer: role_sentence(record),
      info: @role_info,
      value: Atom.to_string(role),
      options: [
        Row.option("primary", "The primary"),
        Row.option("device", "A desktop of the primary"),
        Row.option("candidate", "A candidate waiting for its move")
      ],
      read_only: true,
      restart: Row.restart?(:engine)
    )
  end

  defp executor_rows(%{role: :device}, block) do
    [
      Row.new("engine_executor", :toggle, "Run actions for the primary",
        footer: @executor_footer,
        info: @executor_info,
        value: Role.executor?(block),
        restart: Row.restart?(:engine)
      )
    ]
  end

  defp executor_rows(_record, _block), do: []

  @doc "The sentence the role row carries for the record it describes."
  @spec role_sentence(Role.record()) :: String.t()
  def role_sentence(%{role: :primary}),
    do: "Fermix's chats, memory and channels live on this computer."

  def role_sentence(%{role: :device, primary: name}) when is_binary(name) and name != "",
    do: "Fermix lives on #{name}; this computer carries its chats and runs what you allow."

  def role_sentence(%{role: :device}),
    do: "Fermix lives on its primary; this computer carries its chats and runs what you allow."

  def role_sentence(%{role: :candidate}),
    do: "This computer waits to become the primary through a move."

  @doc """
  Writes one `settings.apply` of the section: the changed `executor`, merged
  into `[fermix_core.engine]` and saved through the path every save takes
  (`Wizard.commit_snapshot/2`), which also applies it to this engine. The role
  is never written here.
  """
  @spec save(keyword()) :: {:ok, map()} | {:error, term()}
  def save(answers) when is_list(answers) do
    unknown = Keyword.keys(answers) -- @answers

    if unknown != [] do
      raise ArgumentError, "unknown engine setting(s): #{inspect(unknown)}"
    end

    snapshot = ConfigStore.current_snapshot()

    engine =
      snapshot.fermix_core
      |> Keyword.get(:engine, [])
      |> Role.normalize()
      |> Keyword.merge(answers)
      |> Role.normalize()

    core = Keyword.put(snapshot.fermix_core, :engine, engine)

    with {:ok, _report} <- Wizard.commit_snapshot(%{snapshot | fermix_core: core}),
         do: {:ok, %{}}
  end
end
