defmodule Fil.Plugin.ContentType do
  @schema NimbleOptions.new!(
            default: [
              type: :string,
              default: "application/octet-stream",
              doc: "The content type for a path whose extension [MIME](https://hex.pm/packages/mime) doesn't know."
            ]
          )

  @moduledoc """
  Sets the content type of a write from the file extension.

      disk =
        Fil.disk(adapter: Fil.Adapter.S3, bucket: "docs")
        |> Fil.Plugin.ContentType.attach()

      Fil.write(disk, "reports/q3.pdf", pdf)
      # stored as application/pdf

  A `content_type:` given to the call wins. Only writes are changed, including the write half of a copy across disks. A
  copy within one disk keeps the source's content type. The local filesystem stores no content type, so this plugin is
  only useful on object stores.

  The extension is looked up with [MIME](https://hex.pm/packages/mime), which you can extend with your own types in your
  config (see its docs).

  It's also the smallest complete example of a plugin module (see the [Plugins guide](plugins.md)): a public callback that validates its
  options, handles one operation and passes the rest on, and an `attach/2` for piping.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias Fil.Op

  @doc """
  Attaches the plugin to `disk` under the name `Fil.Plugin.ContentType`.

  The same as `plugins: [{Fil.Plugin.ContentType, :call, opts}]` in `Fil.disk/1`, except that the options are validated
  here instead of on the first write.
  """
  @spec attach(Fil.Disk.t(), keyword()) :: Fil.Disk.t()
  def attach(%Fil.Disk{} = disk, opts \\ []) do
    Fil.attach(disk, __MODULE__, {__MODULE__, :call}, NimbleOptions.validate!(opts, @schema))
  end

  @doc false
  @spec call(Op.t(), (Op.t() -> Op.t()), keyword()) :: Op.t()
  def call(%Op{name: :write} = op, next, opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    op
    |> Op.put_new_option(:content_type, content_type(op.path, opts[:default]))
    |> next.()
  end

  def call(op, next, _opts), do: next.(op)

  defp content_type(path, default) do
    extension =
      path
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()

    if MIME.has_type?(extension), do: MIME.type(extension), else: default
  end
end
