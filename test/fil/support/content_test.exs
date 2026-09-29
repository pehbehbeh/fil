defmodule Fil.Support.ContentTest do
  alias Fil.Support.Content

  use ExUnit.Case, async: true

  describe "known_size/1" do
    @describetag :tmp_dir

    test "is the size of the file a stream of bytes reads, from its offset", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "a.txt")
      File.write!(path, "content")

      assert {7, _mismatch} =
               path
               |> File.stream!(2)
               |> Content.known_size()

      assert {5, _mismatch} =
               path
               |> File.stream!(2, read_offset: 2)
               |> Content.known_size()

      assert {0, _mismatch} =
               path
               |> File.stream!(2, read_offset: 8)
               |> Content.known_size()
    end

    test "is unknown for a stream that doesn't read the file's bytes as they are", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "a.txt")
      File.write!(path, "content")

      for stream <- [
            File.stream!(path),
            File.stream!(path, 2, [:compressed]),
            File.stream!(path, 2, [:trim_bom]),
            File.stream!(path, 2, encoding: :utf8),
            Stream.map(["content"], & &1)
          ] do
        assert Content.known_size(stream) == nil
      end
    end

    test "is unknown for a file that's empty, missing or not a regular file", %{tmp_dir: tmp_dir} do
      empty = Path.join(tmp_dir, "empty.txt")
      File.write!(empty, "")

      # An empty file may be a pseudo-file (`/proc` on Linux), whose stat says nothing about what it reads.
      for path <- [empty, Path.join(tmp_dir, "missing.txt"), tmp_dir] do
        assert path
               |> File.stream!(2)
               |> Content.known_size() == nil
      end
    end

    @tag skip: if(File.regular?("/proc/cpuinfo"), do: false, else: "needs Linux's /proc")
    test "a pseudo-file of /proc is written as it's read" do
      :ok = Fil.Adapter.Memory.checkout()
      disk = Fil.disk(adapter: Fil.Adapter.Memory)

      assert {:ok, _} = Fil.write(disk, "cpuinfo", File.stream!("/proc/cpuinfo", 4096))
      assert {:ok, cpuinfo} = Fil.read(disk, "cpuinfo")
      assert cpuinfo != ""
    end
  end
end
