defmodule Fil.Plugin.URLTest do
  alias Fil.Plugin.URL

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    disk =
      [adapter: Fil.Adapter.Local, root: tmp_dir]
      |> Fil.disk()
      |> URL.attach(base_url: "http://localhost/storage/", secret: "secret")

    {:ok, disk: disk}
  end

  describe "url/2" do
    test "builds a public URL under the base URL", %{disk: disk} do
      assert Fil.url(disk, "reports/q3 final.pdf") == {:ok, "http://localhost/storage/reports/q3%20final.pdf"}
    end

    test "works without a secret", %{tmp_dir: tmp_dir} do
      disk =
        [adapter: Fil.Adapter.Local, root: tmp_dir]
        |> Fil.disk()
        |> URL.attach(base_url: "http://localhost")

      assert Fil.url(disk, "a.txt") == {:ok, "http://localhost/a.txt"}
    end

    test "replaces the bucket URL of an S3 disk" do
      disk =
        [adapter: Fil.Adapter.S3, bucket: "bucket", region: "eu-central-1"]
        |> Fil.disk()
        |> URL.attach(base_url: "https://cdn.example.com")

      assert Fil.url(disk, "logo.png") == {:ok, "https://cdn.example.com/logo.png"}
    end

    test "rejects paths escaping the root", %{disk: disk} do
      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.url(disk, "../a.txt")
    end
  end

  describe "signed_url/3" do
    test "signs a URL under the base URL", %{disk: disk} do
      assert {:ok, url} = Fil.signed_url(disk, "reports/q3 final.pdf")

      uri = URI.parse(url)
      query = URI.decode_query(uri.query)
      now = System.os_time(:second)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == "http://localhost/storage/reports/q3%20final.pdf"
      assert String.to_integer(query["expires"]) in (now + 890)..(now + 900)
      assert query["signature"] =~ ~r/^[A-Za-z0-9_-]{43}$/
    end

    test "signs GET and PUT differently", %{disk: disk} do
      assert {:ok, get_url} = Fil.signed_url(disk, "a.txt")
      assert {:ok, put_url} = Fil.signed_url(disk, "a.txt", method: :put)

      assert get_url != put_url
    end

    test "caps the expiry at 7 days, as on S3", %{disk: disk} do
      assert {:ok, _url} = Fil.signed_url(disk, "a.txt", expires_in: 7 * 24 * 60 * 60)

      assert_raise ArgumentError, ~r/expires_in/, fn ->
        Fil.signed_url(disk, "a.txt", expires_in: 7 * 24 * 60 * 60 + 1)
      end
    end

    test "rejects paths escaping the root", %{disk: disk} do
      assert {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.signed_url(disk, "../a.txt")
    end

    test "leaves signing to the adapter without a secret", %{tmp_dir: tmp_dir} do
      local =
        [adapter: Fil.Adapter.Local, root: tmp_dir]
        |> Fil.disk()
        |> URL.attach(base_url: "http://localhost")

      assert {:error, %Fil.UnsupportedError{op: :signed_url, reason: :no_callback}} = Fil.signed_url(local, "a.txt")

      s3 =
        [adapter: Fil.Adapter.S3, bucket: "bucket", region: "eu-central-1", access_key_id: "a", secret_access_key: "s"]
        |> Fil.disk()
        |> URL.attach(base_url: "https://cdn.example.com")

      assert {:ok, "https://bucket.s3.eu-central-1.amazonaws.com/a.txt?" <> _} = Fil.signed_url(s3, "a.txt")
    end
  end

  test "passes every other operation on", %{disk: disk} do
    assert {:ok, _} = Fil.write(disk, "a.txt", "a")
    assert Fil.read(disk, "a.txt") == {:ok, "a"}
  end

  test "needs a base URL", %{tmp_dir: tmp_dir} do
    disk = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)

    assert_raise NimbleOptions.ValidationError, ~r/required :base_url option not found/, fn ->
      URL.attach(disk, secret: "secret")
    end
  end

  test "secret/1 reads the secret from the disk", %{disk: disk, tmp_dir: tmp_dir} do
    plain = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)

    assert URL.secret(disk) == "secret"
    assert URL.secret(plain) == nil
    assert URL.secret(URL.attach(plain, base_url: "http://localhost")) == nil
  end

  test "doesn't show the secret", %{disk: disk} do
    refute inspect(disk) =~ "secret"
    refute inspect(Fil.ref(disk, "a.txt")) =~ "secret"
  end
end
