defmodule Fil.ExceptionsTest do
  alias Fil.Adapter.Memory
  alias Fil.Adapter.S3

  use ExUnit.Case, async: true

  describe "messages" do
    test "name the operation, the path, the disk and the reason" do
      disk = Fil.disk(adapter: S3, bucket: "reports")
      error = %Fil.NotFoundError{op: :read, path: "reports/q3.pdf", disk: disk, reason: "NoSuchKey"}

      assert Exception.message(error) == ~s|could not read "reports/q3.pdf" on #Fil.Disk<s3>: no such file (NoSuchKey)|
    end

    test "format every kind of reason" do
      assert message(Fil.UnavailableError, {:http_status, 503}) =~ "the storage is unavailable (HTTP 503)"
      assert message(Fil.UnavailableError, :timeout) =~ "the storage is unavailable (:timeout)"
      assert message(Fil.UnavailableError, %RuntimeError{message: "boom"}) =~ "the storage is unavailable (boom)"

      assert message(Fil.ConfigurationError, {:wrong_region, "us-west-2"}) =~
               ~s|misconfigured ({:wrong_region, "us-west-2"})|

      assert message(Fil.InvalidRequestError, :ebadpath) =~ "invalid request (:ebadpath)"
      assert message(Fil.UnknownError, nil) =~ ~r/: unexpected error$/
    end

    test "use a preposition that fits the operation" do
      assert %Fil.UnsupportedError{op: :signed_url, path: "a.txt"}
             |> Exception.message()
             |> String.starts_with?(~s|could not sign a URL for "a.txt"|)

      assert %Fil.NotFoundError{op: :rm_rf, path: "a"}
             |> Exception.message()
             |> String.starts_with?(~s|could not delete everything under "a"|)
    end

    test "work without an op, a path or an adapter" do
      assert Exception.message(%Fil.StorageFullError{reason: :enospc}) ==
               "could not complete the operation: no space left (:enospc)"
    end

    test "show context filled in after the error was built" do
      Memory.checkout()
      disk = Fil.disk(adapter: Memory)

      assert {:error, error} = Fil.read(disk, "nope.txt")
      assert Exception.message(error) =~ ~s|could not read "nope.txt" on #Fil.Disk<memory>|
    end
  end

  describe "bang variants" do
    test "raise the error from the result" do
      Memory.checkout()
      disk = Fil.disk(adapter: Memory)

      error = assert_raise Fil.NotFoundError, fn -> Fil.read!(disk, "nope.txt") end

      assert {:error, ^error} = Fil.read(disk, "nope.txt")
    end
  end

  defp message(module, reason) do
    module
    |> struct(op: :read, path: "a.txt", reason: reason)
    |> Exception.message()
  end
end
