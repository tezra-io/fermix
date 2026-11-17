defmodule FermixCore.PhoneCalls.UsNumbersTest do
  # Pure module: no processes, no I/O, no global state. Every number here is
  # invented, in the 555-01XX range NANPA reserves for fiction, so none of them
  # reaches anyone.
  use ExUnit.Case, async: true

  alias FermixCore.PhoneCalls.UsNumbers

  describe "classify/1 accepts a number in a US state or DC" do
    test "geographic area codes across the states and DC" do
      for number <- [
            "+12125550142",
            "+14155550101",
            "+12025550199",
            "+19075550123",
            "+18085550150",
            "+17715550142"
          ] do
        assert UsNumbers.classify(number) == :ok, number
      end
    end

    test "every in-service US area code accepts a fictional line" do
      for npa <- UsNumbers.us_area_codes() do
        assert UsNumbers.classify("+1" <> npa <> "5550142") == :ok, npa
      end
    end
  end

  describe "classify/1 refuses +1 numbers that are not in a US state or DC" do
    test "Canada" do
      for npa <- ~w(416 604 514 403 902 867) do
        assert UsNumbers.classify("+1" <> npa <> "5550142") == {:error, :destination_not_us}, npa
      end
    end

    test "the Caribbean and Bermuda" do
      for npa <- ~w(242 246 441 809 876 868 649) do
        assert UsNumbers.classify("+1" <> npa <> "5550142") == {:error, :destination_not_us}, npa
      end
    end

    test "US territories, which are their own destinations" do
      for npa <- ~w(787 939 340 671 670 684) do
        assert UsNumbers.classify("+1" <> npa <> "5550142") == {:error, :destination_not_us}, npa
      end
    end

    test "an area code that is planned but not in service, or never assigned" do
      for npa <- ~w(451 565 761 290 370 999) -- UsNumbers.special_area_codes() do
        assert UsNumbers.classify("+1" <> npa <> "5550142") == {:error, :destination_not_us}, npa
      end
    end

    # Ofcom's and ACMA's ranges for fiction, the UK and Australian 555-01XX.
    test "another country code" do
      assert UsNumbers.classify("+442079460142") == {:error, :destination_not_us}
      assert UsNumbers.classify("+61491570156") == {:error, :destination_not_us}
    end
  end

  describe "classify/1 refuses emergency, service and other special numbers" do
    test "N11 area codes and toll-free, premium and other non-geographic codes" do
      for npa <-
            ~w(211 311 411 511 611 711 811 911 800 833 844 855 866 877 888 900 500 521 700 710 600) do
        assert UsNumbers.classify("+1" <> npa <> "5550142") ==
                 {:error, :emergency_or_special_number},
               npa
      end
    end

    test "N11, premium and access exchanges inside a US area code" do
      for nxx <- ~w(211 311 411 511 611 711 811 911 976 950 958 959) do
        assert UsNumbers.classify("+1212" <> nxx <> "0142") ==
                 {:error, :emergency_or_special_number},
               nxx
      end
    end

    test "555 line numbers outside the fictional 0100-0199 range" do
      assert UsNumbers.classify("+12125551212") == {:error, :emergency_or_special_number}
      assert UsNumbers.classify("+12125550200") == {:error, :emergency_or_special_number}
      assert UsNumbers.classify("+12125550100") == :ok
      assert UsNumbers.classify("+12125550199") == :ok
    end
  end

  describe "classify/1 separates a malformed number from a refused one" do
    test "not E.164" do
      for number <- ["911", "2125550142", "+0125550142", "+1 212 555 0142", "+1212555014a", ""] do
        assert UsNumbers.classify(number) == {:error, :not_e164}, number
      end
    end

    test "+1 numbers of the wrong length or with an area code or exchange NANP never assigns" do
      for number <- [
            "+1212555014",
            "+121255501422",
            "+11125550142",
            "+10125550142",
            "+12121550142",
            "+12120550142"
          ] do
        assert UsNumbers.classify(number) == {:error, :not_nanp_number}, number
      end
    end
  end

  describe "the area code data" do
    test "is NANPA's in-service geographic list for the states and DC, disjoint from the special codes" do
      us = UsNumbers.us_area_codes()
      special = UsNumbers.special_area_codes()

      assert length(us) == 372
      assert length(special) == 116
      assert us == Enum.uniq(us)
      assert special == Enum.uniq(special)
      assert MapSet.disjoint?(MapSet.new(us), MapSet.new(special))
      assert Enum.all?(us ++ special, &Regex.match?(~r/\A[2-9][0-9]{2}\z/, &1))
    end
  end
end
