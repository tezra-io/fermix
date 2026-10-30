defmodule FermixCore.Browser.Handoff.SitesTest do
  # Which sites a hand-off may name, and which cookies each covers (M75 D18).
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Handoff.Sites

  describe "parse/2" do
    test "lower-cases, trims and keeps each site once, in order" do
      assert Sites.parse([" News.Example.org ", "mail.example.net.", "news.example.org"], false) ==
               {:ok, ["news.example.org", "mail.example.net"]}
    end

    test "names a host exactly: no scheme, port, path, wildcard or address" do
      for name <- [
            "https://example.com",
            "example.com:443",
            "example.com/login",
            "*.example.com",
            "example",
            "192.168.1.20",
            "exa mple.com",
            "-example.com",
            ""
          ] do
        assert {:error, {:invalid_site, ^name}} = Sites.parse([name], false), name
      end
    end

    test "refuses a public suffix, which would cover every site under it" do
      assert {:error, {:public_suffix, "co.uk"}} = Sites.parse(["co.uk"], false)
      assert {:error, {:public_suffix, "github.io"}} = Sites.parse(["github.io"], true)
    end

    test "names one to 64 sites" do
      assert {:error, :no_sites} = Sites.parse([], false)
      many = for n <- 1..65, do: "s#{n}.example.com"
      assert {:error, {:too_many_sites, 65}} = Sites.parse(many, false)
      assert {:ok, sites} = Sites.parse(Enum.take(many, 64), false)
      assert length(sites) == 64
    end
  end

  describe "identity providers" do
    test "are refused unless the owner passes the flag" do
      for site <- [
            "accounts.google.com",
            "login.microsoftonline.com",
            "appleid.apple.com",
            "login.live.com",
            "github.com",
            "acme.okta.com",
            "acme.auth0.com",
            "okta.com"
          ] do
        assert {:error, {:identity_provider, ^site}} = Sites.parse([site], false), site
        assert {:ok, [^site]} = Sites.parse([site], true), site
      end
    end

    test "a site that covers one, or is covered by one, is one" do
      assert Sites.identity_provider?("google.com")
      assert Sites.identity_provider?("gist.github.com")
      assert Sites.identity_provider?("eu.login.live.com")
      refute Sites.identity_provider?("mail.google.co")
      refute Sites.identity_provider?("news.example.org")
      refute Sites.identity_provider?("notgithub.com")
    end

    test "the flag covers only the sites named with it" do
      assert {:error, {:identity_provider, "accounts.google.com"}} =
               Sites.parse(["news.example.org", "accounts.google.com"], false)
    end
  end

  describe "covers?/2 and site_for/2" do
    test "a site covers its host and its subdomains, a leading dot ignored" do
      assert Sites.covers?("example.com", "example.com")
      assert Sites.covers?("example.com", ".example.com")
      assert Sites.covers?("example.com", "www.example.com")
      refute Sites.covers?("example.com", "notexample.com")
      refute Sites.covers?("www.example.com", ".example.com")
    end

    test "a cookie belongs to the most specific site that covers it" do
      sites = ["example.com", "mail.example.com"]
      assert Sites.site_for(sites, ".mail.example.com") == "mail.example.com"
      assert Sites.site_for(sites, "www.example.com") == "example.com"
      assert Sites.site_for(sites, "example.org") == nil
    end
  end
end
