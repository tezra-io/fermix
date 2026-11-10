defmodule FermixCore.Home.Candidate.Return do
  @moduledoc """
  What staging a return settles beyond a move's own staging
  (`FermixCore.Home.Candidate.Activation.stage/6`): a return is Always On's
  move back, which stages the server's copy of the home on the computer the
  home left, beside that computer's retired copy, and the staged settings
  must describe this computer again. This computer's own settings need
  nothing here: they are in its `machine.toml` (`FermixCore.Setup.MachineFile`),
  which never left it, which the return keeps
  (`FermixCore.Home.DeviceLocal`), and which the staged `config.toml` never
  holds. `settle/4` takes the staged `config.toml` text once the move's own
  settling is done and:

    * names the **secret store** this computer used
      (`[fermix_core] secret_store`, read by `SecretWriter.parse_store/1`),
      and where that is the keychain, puts every secret back into it
      (`FermixCore.Home.MoveSecrets.restore/3`, under the staged settings'
      profile): a keychain that refuses fails the staging by name
      (`error_sentence/2`);
    * drops this computer's **own desktop row** from the staged device list,
      the row whose Noise key is `device/desktop_key`'s public half, through
      the rail (`FermixCore.Home.Link`'s `drop_desktop_row/2`); a computer
      with no desktop key holds no row.

  Test seams in `opts`: `:drop_desktop_row` (the rail's function), and
  `MoveSecrets.restore/3`'s `:impl` and `:supervised`.
  """

  alias FermixCore.Home.Archive.ConfigText
  alias FermixCore.Home.DesktopLink
  alias FermixCore.Home.Link
  alias FermixCore.Home.MoveSecrets
  alias FermixCore.Setup.SecretWriter

  @config "config.toml"

  @doc """
  Settles the staged settings `text` of the staged home at `staging` for the
  computer whose home is `home` (see the moduledoc). Answers the new text.
  """
  @spec settle(String.t(), Path.t(), Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def settle(text, home, staging, opts)
      when is_binary(text) and is_binary(home) and is_binary(staging) and is_list(opts) do
    with {:ok, retired} <- read_retired(home),
         {:ok, store} <- retired_store(retired),
         {:ok, text} <- secrets(text, store, staging, opts),
         :ok <- drop_own_row(home, staging, opts) do
      {:ok, text}
    end
  end

  @doc """
  The sentence a person is shown when the keychain refused a secret: each as
  its settings row names it (`names`, `Management.Settings.secret_names/1`).
  """
  @spec error_sentence({:keychain_refused, [String.t(), ...]}, %{String.t() => String.t()}) ::
          String.t()
  def error_sentence({:keychain_refused, [_ | _] = ids}, names) when is_map(names),
    do:
      "This computer's keychain did not take #{MoveSecrets.described(ids, names)}, so Fermix " <>
        "did not move back: unlock it, then move back again."

  # -- the retired settings ---------------------------------------------------

  defp read_retired(home) do
    file = Path.join(home, @config)

    case File.read(file) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:retired_config, {:file, file, reason}}}
    end
  end

  defp retired_store(retired) do
    raw =
      case ConfigText.value(retired, "fermix_core", "secret_store") do
        :absent -> nil
        {:ok, raw} -> string_or_raw(raw)
      end

    case SecretWriter.parse_store(raw) do
      {:ok, store} -> {:ok, store}
      {:error, sentence} -> {:error, {:retired_config, sentence}}
    end
  end

  defp string_or_raw(raw) do
    case ConfigText.string(raw) do
      {:ok, value} -> value
      :error -> raw
    end
  end

  # -- secrets ----------------------------------------------------------------

  defp secrets(text, store, staging, opts) do
    text = ConfigText.put(text, "fermix_core", "secret_store", Jason.encode!(to_string(store)))
    restore_into(store, text, staging, opts)
  end

  defp restore_into(:file, text, _staging, _opts), do: {:ok, text}

  defp restore_into(:keyring, text, staging, opts) do
    case MoveSecrets.restore(text, staging, Keyword.take(opts, [:impl, :supervised])) do
      {:ok, text, _restored} -> {:ok, text}
      {:error, _reason} = error -> error
    end
  end

  # -- the desktop row --------------------------------------------------------

  defp drop_own_row(home, staging, opts) do
    case DesktopLink.read_key(home) do
      {:ok, %{public: public}} -> drop_row(staging, public, opts)
      {:error, {:file, _path, :enoent}} -> :ok
      {:error, reason} -> {:error, {:desktop_key, reason}}
    end
  end

  defp drop_row(staging, public, opts) do
    drop = Keyword.get(opts, :drop_desktop_row, &rail_drop/2)

    case drop.(staging, public) do
      :ok -> :ok
      {:error, reason} -> {:error, {:desktop_row, reason}}
    end
  end

  defp rail_drop(staging, public), do: Link.impl().drop_desktop_row(staging, public)
end
