defmodule FermixCore.PhoneCalls.UsNumbers do
  @moduledoc """
  Whether an E.164 number is one Fermix may dial or present: a number in a US
  state or the District of Columbia that is not an emergency, service or other
  special number (M94 §6, "Who may be called").

  "+1" is not "US". The North American Numbering Plan also numbers Canada, the
  Caribbean, Bermuda and the US territories, so the area code decides. The data
  is NANPA's NPA database (`reports.nanpa.com/public/npa_report.csv`, the file
  dated 16 November 2026), in two lists kept only here:

    * `@us_area_codes`: every area code NANPA lists as in service, geographic,
      country US, located in one of the 50 states or DC (372 codes). Puerto
      Rico, the US Virgin Islands, Guam, the Northern Mariana Islands and
      American Samoa are their own dialing destinations, outside this list.
    * `@special_area_codes`: every code NANPA marks as an easily recognizable
      code (N00, N11 and the repeated-digit codes) or as non-geographic: the
      N11 service and emergency codes, toll-free, premium 900, the 5XX
      personal-communications codes, 700, 710 and the rest (116 codes).

  An area code in neither list (another NANP country, a territory, a code
  planned but not yet in service, or one never assigned) is not a US number.
  The list is an allow list, so a code NANPA adds later is refused until the
  data here names it: the safe side of a stale list.

  Inside a US area code, the exchange can still be special: an N11 exchange,
  976 (premium information services), 950, 958 and 959 (carrier access and
  test codes), and the 555 exchange, except its 0100-0199 lines, which NANPA
  reserves for fiction and assigns to no one. Those fictional lines are what
  tests and evals call.
  """

  @e164 ~r/\A\+[1-9][0-9]{1,14}\z/
  @nanp ~r/\A\+1([2-9][0-9]{2})([2-9][0-9]{2})([0-9]{4})\z/

  @us_area_codes ~w(
    201 202 203 205 206 207 208 209 210 212 213 214 215 216 217 218 219 220 223 224
    225 227 228 229 231 234 235 239 240 248 251 252 253 254 256 260 262 267 269 270
    272 274 276 279 281 283 301 302 303 304 305 307 308 309 310 312 313 314 315 316
    317 318 319 320 321 323 324 325 326 327 329 330 331 332 334 336 337 339 341 346
    347 350 351 352 353 357 360 361 363 364 369 380 385 386 401 402 404 405 406 407
    408 409 410 412 413 414 415 417 419 423 424 425 430 432 434 435 436 440 442 443
    445 447 448 457 458 463 464 465 469 470 471 472 475 478 479 480 483 484 501 502
    503 504 505 507 508 509 510 512 513 515 516 517 518 520 530 531 534 539 540 541
    551 557 559 561 562 563 564 567 570 571 572 573 574 575 580 582 585 586 601 602
    603 605 606 607 608 609 610 612 614 615 616 617 618 619 620 621 623 624 626 628
    629 630 631 636 640 641 645 646 650 651 656 657 659 660 661 662 667 669 678 679
    680 681 682 686 689 701 702 703 704 706 707 708 712 713 714 715 716 717 718 719
    720 724 725 726 727 728 729 730 731 732 734 737 738 740 743 747 748 754 757 760
    762 763 765 769 770 771 772 773 774 775 779 781 785 786 801 802 803 804 805 806
    808 810 812 813 814 815 816 817 818 820 821 826 828 830 831 832 835 837 838 839
    840 843 845 847 848 850 854 856 857 858 859 860 861 862 863 864 865 870 872 878
    901 903 904 906 907 908 909 910 912 913 914 915 916 917 918 919 920 924 925 928
    929 930 931 934 936 937 938 940 941 943 945 947 948 949 951 952 954 956 959 970
    971 972 973 975 978 979 980 983 984 985 986 989
  )

  @special_area_codes ~w(
    200 211 222 233 244 255 266 277 288 299 300 311 322 333 344 355 366 377 388 399
    400 411 422 433 444 455 466 477 488 499 500 511 521 522 523 524 525 526 527 528
    529 532 533 535 538 542 543 544 545 546 547 549 550 552 553 554 555 556 558 566
    569 577 578 588 589 599 600 611 622 633 644 655 666 677 688 699 700 710 711 722
    733 744 755 766 777 788 799 800 811 822 833 844 855 866 877 880 881 882 883 884
    885 886 887 888 889 899 900 911 922 933 944 955 966 977 988 999
  )

  @special_exchanges ~w(211 311 411 511 611 711 811 911 950 958 959 976)

  @us MapSet.new(@us_area_codes)
  @special MapSet.new(@special_area_codes)

  unless MapSet.disjoint?(@us, @special) and length(@us_area_codes) == MapSet.size(@us) and
           length(@special_area_codes) == MapSet.size(@special) do
    raise CompileError, description: "UsNumbers: the area code lists overlap or repeat a code"
  end

  @type reason ::
          :not_e164 | :not_nanp_number | :destination_not_us | :emergency_or_special_number

  @doc """
  `:ok` for a number in a US state or DC that is not special, or the reason it
  is not one: `:not_e164` (not an E.164 number at all), `:not_nanp_number` (a
  +1 number NANP could never assign), `:destination_not_us`, or
  `:emergency_or_special_number`.
  """
  @spec classify(String.t()) :: :ok | {:error, reason()}
  def classify(number) when is_binary(number) do
    cond do
      not Regex.match?(@e164, number) -> {:error, :not_e164}
      not String.starts_with?(number, "+1") -> {:error, :destination_not_us}
      true -> classify_nanp(Regex.run(@nanp, number, capture: :all_but_first))
    end
  end

  @doc "The in-service US area codes, as NANPA lists them."
  @spec us_area_codes() :: [String.t(), ...]
  def us_area_codes, do: @us_area_codes

  @doc "The area codes that are special wherever they appear."
  @spec special_area_codes() :: [String.t(), ...]
  def special_area_codes, do: @special_area_codes

  defp classify_nanp(nil), do: {:error, :not_nanp_number}

  defp classify_nanp([npa, nxx, line]) do
    cond do
      MapSet.member?(@special, npa) -> {:error, :emergency_or_special_number}
      not MapSet.member?(@us, npa) -> {:error, :destination_not_us}
      special_exchange?(nxx, line) -> {:error, :emergency_or_special_number}
      true -> :ok
    end
  end

  defp special_exchange?("555", "01" <> _fictional), do: false
  defp special_exchange?("555", _line), do: true
  defp special_exchange?(nxx, _line), do: nxx in @special_exchanges
end
