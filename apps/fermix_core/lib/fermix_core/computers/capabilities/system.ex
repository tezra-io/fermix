defmodule FermixCore.Computers.Capabilities.System do
  @moduledoc """
  `system` (M97 §6): what a computer answers about itself, gated by its
  master switch alone. One operation, harmless: `echo`, which answers the
  text it was given (at most #{1_024} bytes), when it answered and the
  engine version it runs. It changes nothing, so a lost answer is simply
  asked again.
  """

  @behaviour FermixCore.Computers.Capability

  alias FermixCore.BuildInfo

  @max_text_bytes 1_024

  @impl true
  def id, do: :system

  @impl true
  def offer, do: nil

  @impl true
  def ops, do: ["echo"]

  @impl true
  def effect?("echo"), do: false

  @impl true
  def long_lived?("echo"), do: false

  @impl true
  def validate("echo", %{"text" => text} = args) when map_size(args) == 1 and is_binary(text) do
    if byte_size(text) <= @max_text_bytes and String.valid?(text),
      do: :ok,
      else: {:error, "Give echo a text of at most #{@max_text_bytes} bytes."}
  end

  def validate("echo", _args), do: {:error, "Echo takes one argument, its text."}

  @impl true
  def bounds("echo"), do: %{result_bytes: 4_096, part_bytes: 0}

  @impl true
  def admit("echo", _args, _context), do: :ok

  @impl true
  def run("echo", %{"text" => text}, nil, context) do
    at = context.clock.() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    {:ok, %{"text" => text, "at" => at, "engine_version" => BuildInfo.product_version()}, nil}
  end

  def run("echo", _args, _part, _context), do: {:failed, "Echo takes no file."}

  @impl true
  def target("echo", _args), do: "echo"
end
