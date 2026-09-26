defmodule Fil.Plugin.SignedURLTest do
  alias Fil.Plugin.SignedURL

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    disk =
      [adapter: Fil.Adapter.Local, root: tmp_dir]
      |> Fil.disk()
      |> SignedURL.attach(base_url: "http://localhost/storage/", secret: "secret")

    {:ok, disk: disk}
  end

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
    assert Fil.signed_url(disk, "a.txt", expires_in: 7 * 24 * 60 * 60 + 1) == {:error, {:invalid_option, :expires_in}}
  end

  test "rejects paths escaping the root", %{disk: disk} do
    assert Fil.signed_url(disk, "../a.txt") == {:error, :ebadpath}
  end

  test "passes every other operation on", %{disk: disk} do
    assert {:ok, _} = Fil.write(disk, "a.txt", "a")
    assert Fil.read(disk, "a.txt") == {:ok, "a"}
  end

  test "needs a base URL and a secret", %{tmp_dir: tmp_dir} do
    disk = Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)

    assert_raise NimbleOptions.ValidationError, ~r/required :base_url option not found/, fn ->
      SignedURL.attach(disk, secret: "secret")
    end

    assert_raise NimbleOptions.ValidationError, ~r/required :secret option not found/, fn ->
      SignedURL.attach(disk, base_url: "http://localhost")
    end
  end

  test "secret/1 reads the secret from the disk", %{disk: disk, tmp_dir: tmp_dir} do
    assert SignedURL.secret(disk) == "secret"
    assert SignedURL.secret(Fil.disk(adapter: Fil.Adapter.Local, root: tmp_dir)) == nil
  end

  test "doesn't show the secret", %{disk: disk} do
    refute inspect(disk) =~ "secret"
    refute inspect(Fil.ref(disk, "a.txt")) =~ "secret"
  end
end
