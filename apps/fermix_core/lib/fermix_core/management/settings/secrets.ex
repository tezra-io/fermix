defmodule FermixCore.Management.Settings.Secrets do
  @moduledoc """
  The `secrets` section: which store a new secret is written to.

  One row, `[fermix_core] secret_store`, whose two options are its whole value
  space. It is the management door's way to the file store that a terminal
  reaches with `fermix setup --secret-store file`: on a Linux desktop that logs
  in with a fingerprint the login keyring stays locked, so a key saved from the
  app raised an unlock prompt for a password its owner may not know, and the
  app had no way to choose the other store.

  Choosing a store moves nothing. A secret already saved keeps the sentinel
  that names its store and is read back from there; `fermix setup
  --migrate-secrets` is the one mover. The write takes the path every save
  takes (`Wizard.save_answers/2`), and saving applies the store to application
  environment, so the very next `secret.set` writes to it and the row asks for
  no restart.
  """

  alias FermixCore.Management.Settings.Row
  alias FermixCore.Management.Settings.Source
  alias FermixCore.Setup.SecretWriter

  @section %{id: "secrets", pane: "secrets", title: "Secrets"}

  @info "Fingerprint or automatic login leaves your login keyring locked, so saving a " <>
          "key asks for its password. A private file needs no password: each secret is " <>
          "kept in its own file in your Fermix home, readable only by your account and " <>
          "not encrypted. Secrets you already saved stay where they are, and " <>
          "`fermix setup --migrate-secrets` moves them."

  @doc "The one section this module owns."
  @spec sections() :: [%{id: String.t(), pane: String.t(), title: String.t()}]
  def sections, do: [@section]

  @doc "Whether this module owns the named section."
  @spec owns?(String.t()) :: boolean()
  def owns?(section) when is_binary(section), do: section == @section.id

  @doc "The rows of the owned section."
  @spec rows(String.t(), Source.snapshot()) :: [Row.t()]
  def rows("secrets", snapshot) when is_map(snapshot) do
    [
      Row.new("secret_store", :choice, "Keep secrets in",
        footer: "A private file sits in your Fermix home, and only your account can read it.",
        info: @info,
        value: store(snapshot),
        options: [
          Row.option("keyring", "Your keyring"),
          Row.option("file", "A private file")
        ],
        restart: Row.restart?(:secret_store)
      )
    ]
  end

  # A home that never chose holds nothing, which is the keyring, and
  # `SecretWriter.parse_store/1` is the one reading of both. An unknown value
  # never reaches a snapshot: the settings file loader refuses it by name.
  defp store(snapshot) do
    {:ok, store} =
      snapshot
      |> Map.get(:fermix_core, [])
      |> Keyword.get(:secret_store)
      |> SecretWriter.parse_store()

    Atom.to_string(store)
  end
end
