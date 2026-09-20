defmodule FermixCore.ComputerUse.Capabilities do
  @moduledoc """
  What the installed helper says it can do, read from the `hello` it answers at
  the handshake (M42 slice 5 §4).

  The handshake already read this identity, and the transport answers a second
  `hello` from the cached copy without a round trip, so asking costs nothing and
  the answer cannot drift from the helper the session is actually talking to.
  That is why every consumer asks the driver rather than keeping its own record:
  the `ActionWorker` reads it once at start, and `fermix doctor` reads it through
  a one-shot spawn of its own, exactly as `ComputerUse.Probe` does for the
  permission grants.

  `read/1` is tree-less on purpose — no session, no registry, no supervisor —
  because `fermix doctor` runs without the daemon's tree and a row that could
  only be filled in from inside it would print a stacktrace on every host.

  A capability is a claim the build makes about itself, so everything here is
  read CONSERVATIVELY: an absent list is empty, an absent indicator is `:unknown`
  and never `:present`, and nothing is inferred from the protocol version. A
  helper that does not say it has something does not have it.
  """

  alias FermixCore.ComputerUse.PortDriver
  alias FermixCore.ComputerUse.SidecarInstaller

  @type t :: %{
          input_methods: [String.t()],
          capture_methods: [String.t()],
          targets?: boolean(),
          indicator: :present | :missing | :unknown
        }

  @doc """
  Spawn the installed helper, read its `hello`, and stop it again.

  `:driver` and `:binary_path` are the test seams `Probe.run/1` uses; the Port is
  closed on every path, including the one where the read fails.
  """
  @spec read(keyword()) :: {:ok, t()} | {:error, term()}
  def read(opts \\ []) when is_list(opts) do
    driver = Keyword.get(opts, :driver, PortDriver)

    with {:ok, path} <- resolve_path(opts),
         {:ok, state} <- driver.start(binary_path: path) do
      try do
        hello(driver, state)
      after
        driver.stop(state)
      end
    end
  end

  @doc """
  The capabilities a `hello` reply advertises, read conservatively.

  Takes the whole identity map (the reply's own shape), because `capabilities` is
  a key of it and a reply that carries none is a helper that advertises none.
  """
  @spec from_identity(map()) :: t()
  def from_identity(identity) when is_map(identity) do
    capabilities = map(identity["capabilities"])

    %{
      input_methods: strings(capabilities["input_methods"]),
      capture_methods: strings(capabilities["capture_methods"]),
      targets?: capabilities["targets"] == true,
      indicator: indicator(capabilities["indicator"])
    }
  end

  @doc """
  What a caller that could not ask assumes: nothing.

  Used where the helper is not reachable at all — a driver double that predates
  the handshake, a `hello` that errored. It has to be the same shape as a real
  reading, because the alternative is a `nil` every consumer has to remember to
  check, and the conservative answer is already the right one.
  """
  @spec none() :: t()
  def none,
    do: %{input_methods: [], capture_methods: [], targets?: false, indicator: :unknown}

  defp resolve_path(opts) do
    case Keyword.fetch(opts, :binary_path) do
      {:ok, path} -> {:ok, path}
      :error -> SidecarInstaller.binary_path()
    end
  end

  defp hello(driver, state) do
    case driver.execute(state, %{"action" => "hello"}) do
      {:ok, identity} when is_map(identity) -> {:ok, from_identity(identity)}
      {:ok, other} -> {:error, {:malformed_hello, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `present` and `missing` are the helper's own words for a bundle that ships the
  # on-screen indicator and one that does not. Anything else — an older helper
  # that says nothing, a value this build does not know — is unknown, which is a
  # different fact from missing and gets its own operator sentence.
  defp indicator("present"), do: :present
  defp indicator("missing"), do: :missing
  defp indicator(_absent_or_unknown), do: :unknown

  defp map(value) when is_map(value), do: value
  defp map(_absent), do: %{}

  defp strings(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp strings(_absent), do: []
end
