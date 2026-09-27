defmodule Fil.Support.PartsTest do
  alias Fil.Support.Parts

  use ExUnit.Case, async: true

  # Collects the parts as binaries, so the tests compare content and sizes.
  defp split(chunks, part_size) do
    {:done, last, parts} =
      Parts.reduce(chunks, part_size, [], fn part, parts -> {:cont, [IO.iodata_to_binary(part) | parts]} end)

    {Enum.reverse(parts), IO.iodata_to_binary(last)}
  end

  test "cuts parts of exactly the part size and keeps the rest" do
    assert split(["abc", "de", "fghij", "k"], 4) == {["abcd", "efgh"], "ijk"}
  end

  test "passes a part on only once more content follows" do
    assert split(["abcd"], 4) == {[], "abcd"}
    assert split(["ab", "cd", "efgh"], 4) == {["abcd"], "efgh"}
    assert split(["abcdefgh", "i"], 4) == {["abcd", "efgh"], "i"}
  end

  test "an empty stream is no part and an empty rest" do
    assert split([], 4) == {[], ""}
  end

  test "splits one large chunk into many parts without copying it" do
    chunk = :binary.copy("x", 10 * 1_048_576 + 3)

    {:done, last, parts} =
      Parts.reduce([chunk], 1_048_576, [], fn part, parts -> {:cont, [part | parts]} end)

    assert length(parts) == 10
    assert Enum.all?(parts, &(IO.iodata_length(&1) == 1_048_576))
    assert IO.iodata_length(last) == 3

    # Every piece is a sub-binary of the chunk.
    for [piece] <- parts, do: assert(:binary.referenced_byte_size(piece) == byte_size(chunk))
  end

  test "keeps the chunks of a part as they came" do
    {:done, _last, [part]} = Parts.reduce(["ab", "cd", "e"], 4, [], fn part, parts -> {:cont, [part | parts]} end)

    assert part == ["ab", "cd"]
  end

  test "joins runs of many small chunks" do
    chunks = List.duplicate("a", 4097)

    {:done, last, []} = Parts.reduce(chunks, 1_048_576, [], fn part, parts -> {:cont, [part | parts]} end)

    assert IO.iodata_to_binary(last) == :binary.copy("a", 4097)
    assert length(last) == 5
  end

  test "stops reading when the function halts" do
    test = self()

    stream =
      Stream.resource(
        fn -> 0 end,
        fn count -> {["abcd"], count + 1} end,
        fn _count -> send(test, :closed) end
      )

    assert Parts.reduce(stream, 4, 0, fn _part, count ->
             if count == 2, do: {:halt, {:stopped, count}}, else: {:cont, count + 1}
           end) == {:halted, {:stopped, 2}}

    assert_received :closed
  end
end
