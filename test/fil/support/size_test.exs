defmodule Fil.Support.SizeTest do
  alias Fil.Support.Size

  use ExUnit.Case, async: true

  test "formats bytes in decimal units with one decimal place, without a trailing .0" do
    assert Size.format(0) == "0 B"
    assert Size.format(999) == "999 B"
    assert Size.format(1000) == "1 KB"
    assert Size.format(1500) == "1.5 KB"
    assert Size.format(5_000_000) == "5 MB"
    assert Size.format(2_340_000_000) == "2.3 GB"
    assert Size.format(7_000_000_000_000_000) == "7000 TB"
  end

  test "moves a size that rounds to 1000 on to the next unit" do
    assert Size.format(999_999) == "1 MB"
    assert Size.format(999_949) == "999.9 KB"
  end
end
