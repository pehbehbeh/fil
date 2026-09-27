defmodule Fil.Plugin.ContentTypeTest do
  alias Fil.Adapter.S3
  alias Fil.Plugin.ContentType

  use ExUnit.Case, async: true

  import Plug.Conn

  setup do
    test = self()
    Req.Test.stub(__MODULE__, &s3(&1, test))
  end

  defp disk(opts \\ []) do
    [adapter: S3, bucket: "bucket", req_options: [plug: {Req.Test, __MODULE__}]]
    |> Fil.disk()
    |> ContentType.attach(opts)
  end

  # Answers every request with a 200 instead of reaching S3, and messages the test the content type it was sent.
  defp s3(conn, test) do
    send(test, {:content_type, get_req_header(conn, "content-type")})
    send_resp(conn, 200, "")
  end

  # Runs `fun` and returns the content type of the one request it sent.
  defp sent_content_type(fun) do
    assert {:ok, _} = fun.()
    assert_received {:content_type, content_type}
    List.first(content_type)
  end

  test "sets the content type from the extension" do
    assert sent_content_type(fn -> Fil.write(disk(), "reports/q3.pdf", "%PDF") end) == "application/pdf"
    assert sent_content_type(fn -> Fil.write(disk(), "IMAGE.PNG", "png") end) == "image/png"
  end

  test "falls back to the default for an unknown extension" do
    assert sent_content_type(fn -> Fil.write(disk(), "notes.unknownext", "x") end) == "application/octet-stream"
    assert sent_content_type(fn -> Fil.write(disk(), "Makefile", "x") end) == "application/octet-stream"

    text = disk(default: "text/plain")
    assert sent_content_type(fn -> Fil.write(text, "Makefile", "x") end) == "text/plain"
  end

  test "a content type given to the call wins" do
    assert sent_content_type(fn -> Fil.write(disk(), "a.pdf", "x", content_type: "text/plain") end) == "text/plain"
  end

  test "leaves other operations alone" do
    assert sent_content_type(fn -> Fil.read(disk(), "a.pdf") end) == nil
  end

  test "validates its options" do
    assert_raise NimbleOptions.ValidationError, ~r/unknown options \[:defualt\]/, fn ->
      disk(defualt: "text/plain")
    end
  end
end
