defmodule FermixCore.ComputerUse.Reach do
  @moduledoc """
  Which screens a turn can reach, and whose helper the `computer_use` tool's
  words follow (M97 §6.4, §6.5): one answer for the tool's advertisement, its
  schema and description, and the runtime prompt's rules, so none of them
  keeps a list of its own.

    * `reachable?/1`: this host can drive its own screen
      (`ComputerUse.ready?/0`), or a computer the turn can see offers its
      screen (`Computers.Argument`'s computers, by the `computer_use`
      offer). A screenless server reaches a computer's.
    * `reading/1`: the helper reading of the machine a call runs on when it
      names none (`Computers.Choice`): this host's when it is ready, else the
      one computer offering it; with several, every action any of them
      offers, and the strictest access among them, since the model must name
      one and each refuses what it lacks.
    * `of/1`: a computer's reading, from what its `computer_use` offer
      carries (`helper`: its actions and input methods; `detail`: the access
      level its sandbox mode gives). A computer that did not say its actions
      is read as the pixel set (`HelperActions.pixel/0`).
    * `config/1`: the config a session on that computer's screen runs with
      here: this server's budget and images, courtesy off (the computer runs
      it, where the idle signal is) and the computer's access level.

  A reading's `actions` are final: the bound-window flag of the machine that
  has the helper is already applied (`here/0` applies this host's).
  """

  alias FermixCore.Computers.Argument
  alias FermixCore.Computers.Capabilities.Screen
  alias FermixCore.Computers.Computer
  alias FermixCore.ComputerUse
  alias FermixCore.ComputerUse.Background
  alias FermixCore.ComputerUse.Config
  alias FermixCore.ComputerUse.HelperActions

  @typedoc "What a helper offers and how it sends input, and the access it runs under."
  @type reading :: %{
          actions: [String.t()],
          input_methods: [String.t()],
          access: Config.access()
        }

  @accesses %{"strict" => :strict, "standard" => :standard, "open" => :open}
  @strictness [:strict, :standard, :open]

  @doc "Whether a turn whose loop context is `context` can reach a screen."
  @spec reachable?(map()) :: boolean()
  def reachable?(context) when is_map(context),
    do: ComputerUse.ready?() or offering(context) != []

  @doc "The computers the turn can see that offer their screen now."
  @spec offering(map()) :: [Computer.t()]
  def offering(context) when is_map(context),
    do: Argument.offering(Argument.computers(context), Screen)

  @doc "The reading the tool's words follow on this turn (the moduledoc)."
  @spec reading(map()) :: reading()
  def reading(context) when is_map(context) do
    if ComputerUse.ready?(), do: here(), else: chosen(offering(context))
  end

  @doc "This host's reading: its helper's, with its own bound-window flag applied."
  @spec here() :: reading()
  def here do
    %{actions: actions, input_methods: methods} = HelperActions.reading()
    config = Config.current()

    %{
      actions: if(config.background?, do: actions, else: actions -- Background.actions()),
      input_methods: methods,
      access: config.access
    }
  end

  @doc "A computer's reading, from its `computer_use` offer (the moduledoc)."
  @spec of(Computer.t()) :: reading()
  def of(%Computer{offers: offers}) do
    offer = Enum.find(offers, &(&1.id == "computer_use")) || %{}

    case Map.get(offer, :helper) do
      %{actions: actions, input_methods: methods} ->
        %{
          actions: HelperActions.encodable(actions),
          input_methods: methods,
          access: access(Map.get(offer, :detail))
        }

      _none ->
        %{
          actions: HelperActions.pixel(),
          input_methods: [],
          access: access(Map.get(offer, :detail))
        }
    end
  end

  @doc "What a computer's `computer_use` offer carries of this host's reading (`helper`)."
  @spec offered_helper() :: %{actions: [String.t()], input_methods: [String.t()]}
  def offered_helper, do: Map.take(here(), [:actions, :input_methods])

  @doc "The config a session on `computer`'s screen runs with on the server (the moduledoc)."
  @spec config(Computer.t()) :: Config.t()
  def config(%Computer{} = computer) do
    reading = of(computer)

    %{
      Config.current()
      | enabled?: true,
        access: reading.access,
        courtesy: :off,
        background?: "select_target" in reading.actions
    }
  end

  defp chosen([]), do: here()
  defp chosen([one]), do: of(one)

  defp chosen(several) do
    readings = Enum.map(several, &of/1)

    %{
      actions: HelperActions.encodable(Enum.flat_map(readings, & &1.actions)),
      input_methods: readings |> Enum.flat_map(& &1.input_methods) |> Enum.uniq(),
      access: Enum.find(@strictness, &(&1 in Enum.map(readings, fn r -> r.access end)))
    }
  end

  # The access level a computer's sandbox mode gives; standard where it said none.
  defp access(word), do: Map.get(@accesses, word, :standard)
end
