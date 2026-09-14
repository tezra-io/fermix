defmodule Fermix.CLI.VersionSkew do
  @moduledoc """
  The one typed comparison of installed and running engine identity (M38 §9.2).

  A package manager changes files on disk and does not restart the daemon, so
  "what is installed" and "what is running" are two facts, and `compare/2` is
  the only place either the CLI or Doctor is allowed to decide what their
  disagreement means. `note/2` renders that verdict; nothing else re-derives it.

  **A build id is compared with a build id.** A published engine (`macos_app`,
  `linux_package`) is stamped with one at build time, and a product version is a
  display and package-resolution value — reading skew off it is what makes a
  freshly installed engine look aligned while the old one is still running. An
  absent build id on either side is `unknown`, never `aligned`.

  **A standalone binary carries no build id at all**, because the release job
  stamps none, so its product version *is* its generation. That is a second
  distribution configuration, keyed on the identity's own
  `distribution_identity` field, not a guess made when a build id is missing:
  the field is present on both sides and decides which one is compared.

  **Ownership outranks generation.** A daemon of another distribution or
  another architecture is a conflict whatever its build id says, because a
  lifecycle mutation aimed at it would target a process this engine does not own.
  """

  @type alignment :: :aligned | :pending_restart | :not_running | :unknown | :ownership_conflict

  @doc """
  Compares the installed engine identity with the running one.

  `running` is `nil` when no daemon answered. Both maps are the public identity
  shape (`FermixCore.BuildInfo.public_identity/0`, or `hello`'s `engine` object).
  """
  @spec compare(map(), map() | nil) :: alignment()
  def compare(installed, running)

  def compare(installed, nil) when is_map(installed), do: :not_running

  def compare(installed, running) when is_map(installed) and is_map(running) do
    if conflicting?(installed, running),
      do: :ownership_conflict,
      else: generation(installed, running)
  end

  @doc """
  Renders one alignment verdict for an operator.

  `versions` carries the two product versions for display; the installed side
  defaults to this build's own. An aligned or absent daemon has nothing to say
  and answers `nil`, so a caller prints a line only when there is one.
  """
  @spec note(alignment(), keyword()) :: String.t() | nil
  def note(alignment, versions \\ [])

  def note(alignment, _versions) when alignment in [:aligned, :not_running], do: nil

  def note(:pending_restart, versions) do
    "daemon is running #{running(versions)} but the installed binary is " <>
      "#{installed(versions)} — run `fermix restart` to load it"
  end

  def note(:unknown, _versions) do
    "the daemon did not report a build id, so Fermix cannot tell whether it is " <>
      "running the installed engine"
  end

  def note(:ownership_conflict, _versions) do
    "the daemon answering is a different Fermix build than the one installed here, " <>
      "so this install does not own it"
  end

  # Which field carries this distribution's generation. Read off the installed
  # side, which is this build's own identity and always has one.
  defp generation(installed, running) do
    key = generation_key(Map.get(installed, "distribution_identity"))

    compare_generation(Map.get(installed, key), Map.get(running, key))
  end

  defp generation_key("standalone"), do: "product_version"
  defp generation_key(_published), do: "build_id"

  defp compare_generation(nil, _running), do: :unknown
  defp compare_generation(_installed, nil), do: :unknown
  defp compare_generation(same, same), do: :aligned
  defp compare_generation(_installed, _running), do: :pending_restart

  defp conflicting?(installed, running) do
    differs?(installed, running, "distribution_identity") or
      differs?(installed, running, "architecture")
  end

  defp differs?(installed, running, key) do
    left = Map.get(installed, key)
    right = Map.get(running, key)

    not is_nil(left) and not is_nil(right) and left != right
  end

  defp installed(versions) do
    Keyword.get_lazy(versions, :installed, &current_version/0)
  end

  defp running(versions), do: Keyword.get(versions, :running) || "an unknown version"

  defp current_version do
    case Application.spec(:fermix_core, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
