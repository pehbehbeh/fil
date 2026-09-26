defmodule Fil.ExceptionsTest do
  alias Fil.Adapter.S3

  use ExUnit.Case, async: true

  describe "Fil.Error" do
    test "names the operation, the path and the adapter" do
      error =
        Fil.Error.exception(
          reason: :enoent,
          op: :read,
          path: "reports/q3.pdf",
          adapter: S3
        )

      assert error.message ==
               ~s|could not read "reports/q3.pdf" on Fil.Adapter.S3: no such file or directory|
    end

    test "formats reasons that aren't POSIX errors" do
      assert message(:ebadpath) =~ "the path escapes the disk root"
      assert message(:precondition_failed) =~ "the write precondition failed"
      assert message({:unsupported, :signed_url}) =~ "signed_url is not supported by this adapter"
      assert message({:wrong_region, "us-west-2"}) =~ "different region (us-west-2)"
      assert message({:wrong_region, nil}) =~ "different region"
      assert message({:unexpected_status, 429, "SlowDown"}) =~ "unexpected response (HTTP 429, SlowDown)"
      assert message({:unexpected_status, 429, nil}) =~ "unexpected response (HTTP 429)"
      assert message(:eacces) =~ "permission denied"
      assert message(%Fil.TransportError{reason: :timeout}) =~ "transport error: timeout"
      assert message({:weird, :reason}) =~ "{:weird, :reason}"
    end

    test "inspects atoms that aren't POSIX errors" do
      assert message(:missing_credentials) == ~s|could not read "a.txt": :missing_credentials|
    end

    test "builds a message without an op, path or adapter" do
      error = Fil.Error.exception(reason: :enoent)

      assert error.message == "could not complete the operation: no such file or directory"
    end
  end

  describe "Fil.TransportError" do
    test "describes what went wrong" do
      assert Exception.message(%Fil.TransportError{reason: :timeout}) ==
               "transport error: timeout"

      assert Exception.message(%Fil.TransportError{reason: {:http_status, 503}}) ==
               "transport error: unexpected server response (HTTP 503)"

      assert Exception.message(%Fil.TransportError{reason: %RuntimeError{message: "boom"}}) ==
               "transport error: boom"

      assert Exception.message(%Fil.TransportError{reason: {:closed, 1}}) ==
               "transport error: {:closed, 1}"
    end
  end

  defp message(reason) do
    Fil.Error.exception(reason: reason, op: :read, path: "a.txt").message
  end
end
