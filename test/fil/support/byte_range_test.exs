defmodule Fil.Support.ByteRangeTest do
  alias Fil.Support.ByteRange

  use ExUnit.Case, async: true

  test "a stream reads no chunk past the range" do
    test = self()
    chunks = Stream.map(["ab", "cd", "ef"], &tap(&1, fn chunk -> send(test, {:pulled, chunk}) end))

    assert chunks
           |> ByteRange.slice({1, 2})
           |> Enum.join() == "bc"

    assert_received {:pulled, "ab"}
    assert_received {:pulled, "cd"}
    refute_received {:pulled, "ef"}
  end

  test "a stream with an open end reads to the end" do
    # A list is iodata, so the stream is a `Stream`.
    assert ["ab", "cd", "ef"]
           |> Stream.map(& &1)
           |> ByteRange.slice({3, nil})
           |> Enum.join() == "def"
  end
end
