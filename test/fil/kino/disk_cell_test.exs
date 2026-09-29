defmodule Fil.Kino.DiskCellTest do
  alias Fil.Kino.DiskCell

  use ExUnit.Case, async: true

  import Kino.Test

  setup :configure_livebook_bridge

  @moduletag :tmp_dir

  test "is registered with Kino" do
    assert DiskCell in Enum.map(Kino.SmartCell.definitions(), & &1.module)
    assert %{name: "Fil disk"} = DiskCell.__smart_definition__()
  end

  describe "local" do
    test "generates a local disk" do
      {_kino, source} =
        start_smart_cell!(DiskCell, %{"variable" => "files", "adapter" => "local", "root" => "/tmp/fil"})

      assert source == ~s[files = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")]
    end

    test "evaluates to a disk", %{tmp_dir: tmp_dir} do
      {_kino, source} = start_smart_cell!(DiskCell, %{"variable" => "files", "adapter" => "local", "root" => tmp_dir})
      {disk, _binding} = Code.eval_string(source)

      assert {:ok, _file} = Fil.write(disk, "a.txt", "a")

      assert tmp_dir
             |> Path.join("a.txt")
             |> File.read!() == "a"
    end

    test "leaves out an empty root" do
      {_kino, source} = start_smart_cell!(DiskCell, %{"variable" => "files", "adapter" => "local", "root" => ""})

      assert source == "files = Fil.disk(adapter: Fil.Adapter.Local)"
    end

    test "is the default adapter" do
      {_kino, source} = start_smart_cell!(DiskCell, %{"variable" => "files"})

      assert source == "files = Fil.disk(adapter: Fil.Adapter.Local)"
    end
  end

  describe "memory" do
    test "checks out a store first, and evaluates" do
      {_kino, source} = start_smart_cell!(DiskCell, %{"variable" => "files", "adapter" => "memory", "root" => "a"})

      assert source == """
             Fil.Adapter.Memory.checkout()
             files = Fil.disk(adapter: Fil.Adapter.Memory, root: "a")\
             """

      {disk, _binding} = Code.eval_string(source)
      assert {:ok, _file} = Fil.write(disk, "a.txt", "a")
    end
  end

  describe "s3" do
    test "generates every option, with the credentials from secrets" do
      attrs = %{
        "variable" => "reports",
        "adapter" => "s3",
        "bucket" => "reports",
        "region" => "eu-central-1",
        "root" => "2026",
        "endpoint" => "http://localhost:9000",
        "path_style" => false,
        "access_key_id_secret" => "AWS_ACCESS_KEY_ID",
        "secret_access_key_secret" => "AWS_SECRET_ACCESS_KEY",
        "session_token_secret" => "AWS_SESSION_TOKEN"
      }

      {_kino, source} = start_smart_cell!(DiskCell, attrs)

      assert source == """
             reports =
               Fil.disk(
                 adapter: Fil.Adapter.S3,
                 bucket: "reports",
                 region: "eu-central-1",
                 root: "2026",
                 endpoint: "http://localhost:9000",
                 path_style: false,
                 access_key_id: System.fetch_env!("LB_AWS_ACCESS_KEY_ID"),
                 secret_access_key: System.fetch_env!("LB_AWS_SECRET_ACCESS_KEY"),
                 session_token: System.fetch_env!("LB_AWS_SESSION_TOKEN")
               )\
             """
    end

    test "leaves out empty fields and missing secrets" do
      attrs = %{
        "variable" => "public",
        "adapter" => "s3",
        "bucket" => "public",
        "region" => "",
        "endpoint" => "",
        "path_style" => false,
        "access_key_id_secret" => "",
        "secret_access_key_secret" => "",
        "session_token_secret" => ""
      }

      {_kino, source} = start_smart_cell!(DiskCell, attrs)

      assert source == ~s[public = Fil.disk(adapter: Fil.Adapter.S3, bucket: "public")]
    end
  end

  describe "path_style" do
    test "is left out when it's on with an endpoint, the adapter's default" do
      source = s3_source(%{"endpoint" => "http://localhost:9000", "path_style" => true})

      assert source == ~s[s3 = Fil.disk(adapter: Fil.Adapter.S3, bucket: "b", endpoint: "http://localhost:9000")]
    end

    test "is generated when it's off with an endpoint" do
      source = s3_source(%{"endpoint" => "http://localhost:9000", "path_style" => false})

      assert source == """
             s3 =
               Fil.disk(
                 adapter: Fil.Adapter.S3,
                 bucket: "b",
                 endpoint: "http://localhost:9000",
                 path_style: false
               )\
             """
    end

    test "is generated when it's on without an endpoint" do
      source = s3_source(%{"endpoint" => "", "path_style" => true})

      assert source == ~s[s3 = Fil.disk(adapter: Fil.Adapter.S3, bucket: "b", path_style: true)]
    end

    test "is left out when it's off without an endpoint, the adapter's default" do
      source = s3_source(%{"endpoint" => "", "path_style" => false})

      assert source == ~s[s3 = Fil.disk(adapter: Fil.Adapter.S3, bucket: "b")]
    end

    test "defaults to on with an endpoint" do
      {kino, source} =
        start_smart_cell!(DiskCell, %{"variable" => "s3", "adapter" => "s3", "endpoint" => "http://localhost:9000"})

      assert %{fields: %{"path_style" => true}} = connect(kino)
      assert source == ~s[s3 = Fil.disk(adapter: Fil.Adapter.S3, endpoint: "http://localhost:9000")]
    end

    test "follows the endpoint until it's switched away from the default" do
      {kino, _source} = start_smart_cell!(DiskCell, %{"variable" => "s3", "adapter" => "s3"})
      endpoint = "http://localhost:9000"

      update(kino, "endpoint", endpoint)
      assert_broadcast_event(kino, "update", %{"fields" => %{"endpoint" => ^endpoint, "path_style" => true}})
      assert_smart_cell_update(kino, %{"path_style" => true}, _source)

      update(kino, "endpoint", "")
      assert_broadcast_event(kino, "update", %{"fields" => %{"endpoint" => "", "path_style" => false}})
      assert_smart_cell_update(kino, %{"path_style" => false}, "s3 = Fil.disk(adapter: Fil.Adapter.S3)")

      update(kino, "path_style", false)
      assert_broadcast_event(kino, "update", %{"fields" => %{"path_style" => false}})
      update(kino, "endpoint", endpoint)
      assert_broadcast_event(kino, "update", %{"fields" => %{"endpoint" => ^endpoint, "path_style" => true}})
      assert_smart_cell_update(kino, %{"path_style" => true}, _source)

      update(kino, "path_style", false)
      assert_broadcast_event(kino, "update", %{"fields" => %{"path_style" => false}})
      update(kino, "endpoint", "http://localhost:9090")
      assert_broadcast_event(kino, "update", %{"fields" => fields})
      assert fields == %{"endpoint" => "http://localhost:9090"}
      assert_smart_cell_update(kino, %{"endpoint" => "http://localhost:9090", "path_style" => false}, source)
      assert source =~ "path_style: false"

      update(kino, "endpoint", "")
      assert_broadcast_event(kino, "update", %{"fields" => fields})
      assert fields == %{"endpoint" => ""}

      assert_smart_cell_update(
        kino,
        %{"endpoint" => "", "path_style" => false},
        "s3 = Fil.disk(adapter: Fil.Adapter.S3)"
      )
    end
  end

  describe "the form" do
    test "sends its fields on connect" do
      {kino, _source} = start_smart_cell!(DiskCell, %{"variable" => "files", "adapter" => "memory"})

      assert %{fields: %{"variable" => "files", "adapter" => "memory", "root" => "", "path_style" => false}} =
               connect(kino)
    end

    test "updates the source when a field changes" do
      {kino, _source} = start_smart_cell!(DiskCell, %{"variable" => "files", "adapter" => "local"})

      push_event(kino, "update_field", %{"field" => "adapter", "value" => "s3"})
      assert_broadcast_event(kino, "update", %{"fields" => %{"adapter" => "s3"}})

      assert_smart_cell_update(
        kino,
        %{"adapter" => "s3", "bucket" => ""},
        "files = Fil.disk(adapter: Fil.Adapter.S3)"
      )

      push_event(kino, "update_field", %{"field" => "bucket", "value" => " reports "})

      assert_smart_cell_update(
        kino,
        %{"bucket" => "reports"},
        ~s[files = Fil.disk(adapter: Fil.Adapter.S3, bucket: "reports")]
      )

      push_event(kino, "update_field", %{"field" => "access_key_id_secret", "value" => "KEY"})
      assert_smart_cell_update(kino, %{"access_key_id_secret" => "KEY"}, source)
      assert source =~ ~s[access_key_id: System.fetch_env!("LB_KEY")]
    end

    test "keeps the variable name when the new one isn't valid" do
      {kino, _source} = start_smart_cell!(DiskCell, %{"variable" => "files"})

      push_event(kino, "update_field", %{"field" => "variable", "value" => "not valid"})
      assert_broadcast_event(kino, "update", %{"fields" => %{"variable" => "files"}})

      push_event(kino, "update_field", %{"field" => "variable", "value" => "uploads"})
      assert_smart_cell_update(kino, %{"variable" => "uploads"}, "uploads = Fil.disk(adapter: Fil.Adapter.Local)")
    end

    test "ignores unknown fields and adapters" do
      {kino, _source} = start_smart_cell!(DiskCell, %{"variable" => "files"})

      push_event(kino, "update_field", %{"field" => "adapter", "value" => "ftp"})
      push_event(kino, "update_field", %{"field" => "password", "value" => "secret"})
      push_event(kino, "update_field", %{"field" => "root", "value" => "storage"})

      assert_smart_cell_update(kino, %{"root" => "storage"}, source)
      assert source == ~s[files = Fil.disk(adapter: Fil.Adapter.Local, root: "storage")]
    end
  end

  describe "the variable" do
    test "falls back to the default for an invalid name" do
      {_kino, source} = start_smart_cell!(DiskCell, %{"variable" => "not valid"})

      assert source =~ ~r/^disk\d* = Fil.disk/
    end

    test "defaults to disk, and to another name in the next cell" do
      {_kino, first} = start_smart_cell!(DiskCell, %{})
      {_kino, second} = start_smart_cell!(DiskCell, %{})

      assert [_source, first_name] = Regex.run(~r/^(disk\d*) = /, first)
      assert [_source, second_name] = Regex.run(~r/^(disk\d*) = /, second)
      assert first_name != second_name
    end
  end

  defp update(kino, field, value), do: push_event(kino, "update_field", %{"field" => field, "value" => value})

  defp s3_source(attrs) do
    attrs = Map.merge(%{"variable" => "s3", "adapter" => "s3", "bucket" => "b"}, attrs)
    {_kino, source} = start_smart_cell!(DiskCell, attrs)
    source
  end
end
