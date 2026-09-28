defmodule FermixCore.Setup.MachineFacts do
  @moduledoc """
  The two personalization facts the machine already knows about its user: the
  system time zone and the account's full name.

  The daemon's first boot seeds them into `config.toml` (`Setup.HomeSeeder`),
  and the CLI wizard and the web setup offer the time zone as their default, so
  every door into setup starts from the same answers and none of them invents
  a value. A fact the machine cannot provide is `:error`, never a placeholder:
  `Readiness` then reports the value as missing, and `Prompt.Defaults` renders
  its stand-in until someone types one.

  The reader is `MachineFacts.Host`. `config/test.exs` pins
  `FermixTestSupport.MachineFactsStub` in its place, because a test that read
  the host's `/etc/localtime` or ran `id -F` would answer differently on every
  machine.
  """

  @callback timezone() :: {:ok, String.t()} | :error
  @callback full_name() :: {:ok, String.t()} | :error

  @doc "The system time zone as an IANA name, or `:error` when the machine cannot say."
  @spec timezone() :: {:ok, String.t()} | :error
  def timezone, do: source().timezone()

  @doc "The account's full name, or `:error` when the machine cannot say."
  @spec full_name() :: {:ok, String.t()} | :error
  def full_name, do: source().full_name()

  defp source, do: Application.get_env(:fermix_core, :machine_facts, __MODULE__.Host)
end
