defmodule FermixCore.Home.Provision.ProviderContractTest do
  # M75 lean v1 §4.3: every cloud provider Always On creates a server on is
  # one module behind `FermixCore.Home.Provision`, listed in
  # `Provision.Registry`. The shared code (the contract's own functions, the
  # ledger, the job, the summary, Copy and the management family) reaches a
  # provider only through it, so an invented second provider
  # (`FermixTestSupport.FakeCloudProvider`) runs the same shared code, and no
  # shared module names Hetzner.
  use ExUnit.Case, async: true

  alias FermixCore.Home.Provision
  alias FermixCore.Home.Provision.Hetzner
  alias FermixCore.Home.Provision.Ledger
  alias FermixCore.Home.Provision.Registry
  alias FermixCore.Management.Copy
  alias FermixTestSupport.FakeCloudProvider
  alias FermixTestSupport.SafeRm
  alias FermixTestSupport.TestSourceScan

  @earlier ~U[2031-05-04 09:00:00Z]
  @later ~U[2031-05-04 10:00:00Z]
  # The files that may name Hetzner: its own module and the registry that
  # lists it.
  @named_here ~w(apps/fermix_core/lib/fermix_core/home/provision/hetzner.ex
                 apps/fermix_core/lib/fermix_core/home/provision/registry.ex)

  setup do
    home = SafeRm.make_tmp_dir!("provision-contract")
    on_exit(fn -> SafeRm.rm_rf!(home) end)
    %{home: home}
  end

  describe "the registry" do
    test "lists Hetzner, the one provider today, found by its id" do
      assert Registry.all() == [Hetzner]
      assert Provision.provider(Registry.all(), "hetzner") == {:ok, Hetzner}
      assert Provision.provider(Registry.all(), "nimbus") == :error

      assert Provision.provider([Hetzner, FakeCloudProvider], "nimbus") ==
               {:ok, FakeCloudProvider}
    end
  end

  describe "every provider" do
    for provider <- [Hetzner, FakeCloudProvider] do
      @provider provider

      test "#{inspect(provider)} implements every callback of the contract" do
        Code.ensure_loaded!(@provider)

        for {name, arity} <- Provision.behaviour_info(:callbacks),
            do: assert(function_exported?(@provider, name, arity), "#{name}/#{arity}")
      end

      test "#{inspect(provider)}'s display data is whole, and its words obey the copy rules" do
        display = @provider.display()
        names = display.proper_nouns

        assert Regex.match?(~r/\A[a-z][a-z0-9-]{1,31}\z/, @provider.id())
        assert display.name in names
        assert String.starts_with?(display.console_url, "https://")
        assert Regex.match?(~r/\A[a-z0-9-]+\z/, display.docs_anchor)
        assert [_one | _more] = display.locations
        assert length(display.steps) >= 3

        # L20: two-factor sign-in first, and an account for Fermix alone.
        assert hd(display.steps) =~ "two-factor sign-in"
        assert Enum.at(display.steps, 1) =~ "for Fermix alone"

        for %{id: id, city: city} <- display.locations do
          assert Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,31}\z/, id)
          assert city in names
        end

        for {text, kind} <-
              [{display.token_label, :name}, {display.write_token, :name}] ++
                Enum.map(display.steps, &{&1, :prose}) do
          assert Copy.violations(text, kind, names) == [], inspect(text)
          assert Copy.summary_violations(text) == [], inspect(text)
        end
      end
    end
  end

  describe "names, the same for every provider" do
    test "a server is named by profile and a short id" do
      assert Provision.server_name("general", "a3f9") == "fermix-general-a3f9"
      assert Provision.server_name("Ops & Co.", "0007") == "fermix-ops-co-0007"
      assert Provision.name_part("---") =~ ~r/\Ap[0-9a-f]{8}\z/
    end

    test "a new server's short id is never the one it replaces" do
      assert Provision.fresh_ref(<<0xA3, 0xF9>>, nil) == "a3f9"
      assert Provision.fresh_ref(<<0x00, 0x07>>, "a3f9") == "0007"
      assert Provision.fresh_ref(<<0xA3, 0xF9>>, "a3f9") == "a3fa"
      assert Provision.fresh_ref(<<0xFF, 0xFF>>, "ffff") == "0000"
    end
  end

  describe "the provider Always On speaks of (current/2)" do
    test "with nothing anywhere, the first the registry offers", ctx do
      assert Provision.current(ctx.home, [Hetzner, FakeCloudProvider]) == Hetzner
      assert Provision.current(ctx.home, [FakeCloudProvider, Hetzner]) == FakeCloudProvider
    end

    test "the provider whose token was given last", ctx do
      connect!(ctx.home, Hetzner, @earlier)
      connect!(ctx.home, FakeCloudProvider, @later)

      assert Provision.current(ctx.home, [Hetzner, FakeCloudProvider]) == FakeCloudProvider
    end

    test "the provider that holds what Fermix created, over a newer token", ctx do
      connect!(ctx.home, Hetzner, @earlier)

      {:ok, _ledger} =
        Ledger.update(ctx.home, "hetzner", &{:ok, Ledger.begin_create(&1, "a3f9", %{name: "n"})})

      connect!(ctx.home, FakeCloudProvider, @later)

      assert Provision.current(ctx.home, [FakeCloudProvider, Hetzner]) == Hetzner
    end

    test "a file that cannot be read may hold a server, so it is the one", ctx do
      connect!(ctx.home, FakeCloudProvider, @later)
      File.write!(Ledger.path(ctx.home, "hetzner"), "not a ledger")

      assert Provision.current(ctx.home, [FakeCloudProvider, Hetzner]) == Hetzner
    end
  end

  describe "the shared sentences, in each provider's words" do
    test "a shared kind names the provider it came from" do
      assert Provision.error_sentence(:account_limit, FakeCloudProvider) ==
               "Nimbus limits new servers on this account."

      assert Provision.error_sentence(:account_limit, Hetzner) ==
               "Hetzner limits new servers on this account."

      assert Provision.error_sentence(:token_invalid, FakeCloudProvider) ==
               "Nimbus does not accept this token, so paste a key that may create servers " <>
                 "from the Nimbus workspace you made for Fermix."

      assert Provision.error_sentence(:read_only_token, FakeCloudProvider) ==
               "This token can only read, so Fermix created nothing; paste a key that may " <>
                 "create servers from your Nimbus workspace."

      assert Provision.error_sentence(:no_token, FakeCloudProvider) ==
               "Paste a Nimbus access key first."

      assert Provision.error_sentence({:rate_limited, nil}, FakeCloudProvider) ==
               "Nimbus is limiting how often Fermix may ask, so try again in a few minutes."
    end

    test "the provider's own refusal is its plain sentence, kept as other" do
      reason = {:other, "Nimbus has no image for that place right now."}

      assert Provision.error_sentence(reason, FakeCloudProvider) ==
               "Nimbus has no image for that place right now."

      assert Provision.failure_word(reason) == "other"
      assert Provision.failure_word(:read_only_token) == "read_only_token"
      assert Provision.failure_word(:account_limit) == "account_limit"
      assert Provision.failure_word({:unavailable, %{}}) == "unavailable"
    end

    test "every refusal Hetzner's own errors become is a shared kind" do
      for reason <- [
            :forbidden,
            :not_found,
            :resource_in_use,
            :resource_unavailable,
            :no_image,
            :too_many_types,
            {:ineligible_type, "cpx12"},
            {:refused, 422, "invalid_input", "invalid input in field 'server_type'"},
            {:action_failed, "create_server", "server placement failed"},
            {:action_timeout, "start_server"}
          ] do
        shared = Hetzner.error(reason)
        assert shared == :read_only_token or match?({:other, _sentence}, shared), inspect(reason)
        assert Provision.error_sentence(shared, Hetzner) =~ ~r/\A[A-Z].*[.]\z/
      end
    end
  end

  describe "the shared modules" do
    # The code a new provider plugs into reaches it through the contract
    # only: a Hetzner word anywhere else is a Hetzner assumption.
    test "name no provider: only Hetzner's own module and the registry say Hetzner" do
      offenders =
        for file <- lib_files(),
            relative = TestSourceScan.relative_path(file),
            relative not in @named_here,
            File.read!(file) =~ ~r/hetzner/i,
            do: relative

      assert offenders == []
    end

    test "the scan reads every shared provisioning module" do
      scanned = Enum.map(lib_files(), &TestSourceScan.relative_path/1)

      for file <-
            ~w(home/provision.ex home/provision/ledger.ex home/provision/first_boot.ex
               management/provision.ex management/home_summary.ex management/copy.ex
               management/jobs.ex management/home.ex management/router.ex) do
        assert ("apps/fermix_core/lib/fermix_core/" <> file) in scanned, file
      end

      assert Enum.all?(@named_here, &(&1 in scanned))
      assert length(scanned) > 500
    end
  end

  defp lib_files,
    do: Path.wildcard(Path.join(TestSourceScan.umbrella_root(), "apps/*/lib/**/*.ex"))

  defp connect!(home, provider, at) do
    {:ok, _ledger} =
      Ledger.update(
        home,
        provider.id(),
        &{:ok, Ledger.connect(&1, "invented-token-#{provider.id()}-0001", at)}
      )

    :ok
  end
end
