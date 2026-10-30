defmodule FermixCore.Browser.Handoff.CookiesTest do
  # The cookies a hand-off carries: selected by site, checked by the primary,
  # stored no longer than the hand-off and deleted by key (M75 D18).
  use ExUnit.Case, async: true

  alias FermixCore.Browser.Handoff.Cookies

  @session %{
    "name" => "sid",
    "value" => "v-session",
    "domain" => ".news.example.org",
    "path" => "/",
    "expires" => -1,
    "size" => 13,
    "httpOnly" => true,
    "secure" => true,
    "session" => true,
    "sameSite" => "Lax",
    "priority" => "Medium",
    "sourceScheme" => "Secure",
    "sourcePort" => 443
  }
  @host_only %{
    "name" => "pref",
    "value" => "dark",
    "domain" => "mail.example.net",
    "path" => "/inbox",
    "expires" => 1_900_000_000.5,
    "httpOnly" => false,
    "secure" => false,
    "session" => false
  }
  @other %{
    "name" => "x",
    "value" => "y",
    "domain" => ".tracker.example.com",
    "path" => "/",
    "expires" => -1,
    "httpOnly" => false,
    "secure" => false
  }
  @partitioned Map.put(@session, "partitionKey", %{"topLevelSite" => "https://example.com"})
  @sites ["news.example.org", "mail.example.net"]

  describe "select/2" do
    test "keeps exactly the named sites' cookies, each tagged with its site" do
      selected = Cookies.select([@session, @host_only, @other, @partitioned], @sites)

      assert Enum.map(selected, & &1["site"]) == ["news.example.org", "mail.example.net"]
      assert Enum.map(selected, & &1["name"]) == ["sid", "pref"]
      refute Enum.any?(selected, &Map.has_key?(&1, "size"))
      refute Enum.any?(selected, &Map.has_key?(&1, "session"))
    end
  end

  describe "decode/3" do
    test "answers what was encoded" do
      cookies = Cookies.select([@session, @host_only], @sites)
      assert {:ok, ^cookies} = Cookies.decode(Cookies.encode(cookies), @sites, 2)
    end

    test "refuses a cookie for a site the hand-off did not name" do
      foreign = Map.put(@other, "site", "tracker.example.com")
      payload = Cookies.encode([foreign])

      assert {:error, {:invalid_cookie, "x for .tracker.example.com"}} =
               Cookies.decode(payload, @sites, 1)

      lying = Map.put(@other, "site", "news.example.org")

      assert {:error, {:invalid_cookie, _label}} =
               Cookies.decode(Cookies.encode([lying]), @sites, 1)
    end

    test "refuses another count, a malformed cookie and a payload that is not JSON" do
      [cookie] = Cookies.select([@session], @sites)
      payload = Cookies.encode([cookie])

      assert {:error, {:count_mismatch, 1, 2}} = Cookies.decode(payload, @sites, 2)
      assert {:error, :invalid_payload} = Cookies.decode("not json", @sites, 1)

      for {field, bad} <- [{"path", "inbox"}, {"secure", "yes"}, {"sameSite", "Sometimes"}] do
        broken = Cookies.encode([Map.put(cookie, field, bad)])
        assert {:error, {:invalid_cookie, _label}} = Cookies.decode(broken, @sites, 1), field
      end
    end

    test "a refusal never carries a value" do
      payload =
        Cookies.encode([
          Map.merge(@other, %{"site" => "elsewhere.example", "value" => "SECRETV"})
        ])

      {:error, reason} = Cookies.decode(payload, @sites, 1)
      refute inspect(reason) =~ "SECRETV"
    end
  end

  describe "set_params/2" do
    test "a session cookie lasts until the hand-off expires, and keeps its domain" do
      [cookie] = Cookies.select([@session], @sites)
      params = Cookies.set_params(cookie, 1_800_000_000)

      assert params["expires"] == 1_800_000_000
      assert params["domain"] == ".news.example.org"
      assert params["url"] == "https://news.example.org/"
      assert params["sameSite"] == "Lax"
      refute Map.has_key?(params, "site")
    end

    test "a cookie never outlives the hand-off, and a host-only one stays host-only" do
      [cookie] = Cookies.select([@host_only], @sites)

      assert Cookies.set_params(cookie, 1_800_000_000)["expires"] == 1_800_000_000
      assert Cookies.set_params(cookie, 2_000_000_000)["expires"] == 1_900_000_000.5

      params = Cookies.set_params(cookie, 1_800_000_000)
      assert params["url"] == "http://mail.example.net/inbox"
      refute Map.has_key?(params, "domain")
    end
  end

  describe "delete_params/1" do
    test "expires the cookie its key names, from a secure address" do
      key = Cookies.key(hd(Cookies.select([@session], @sites)))

      assert key == %{
               "site" => "news.example.org",
               "domain" => ".news.example.org",
               "name" => "sid",
               "path" => "/"
             }

      params = Cookies.delete_params(key)
      assert params["expires"] == 1
      assert params["secure"] == true
      assert params["url"] == "https://news.example.org/"
      assert params["domain"] == ".news.example.org"
      assert params["value"] == ""
    end
  end
end
