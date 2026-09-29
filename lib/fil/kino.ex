if Code.ensure_loaded?(Kino.JS.Live) do
  defmodule Fil.Kino do
    @moduledoc """
    Browses disks in [Livebook](https://livebook.dev), uploads files to them, and adds a smart cell that builds a disk.

        Mix.install([{:fil, "~> 0.2"}, {:kino, "~> 0.19"}])

        disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
        Fil.Kino.browser(disk)

    Needs [Kino](https://hexdocs.pm/kino), an optional dependency of `Fil`.

    ## Browser

    `browser/3` shows one directory of a disk at a time: breadcrumbs back to the root, and a table with the name, size,
    modification time and type of each entry. Clicking a directory opens it. Clicking a file shows a preview below the
    table, for images (PNG, JPEG, GIF and WebP) and text, and each file has a download button.

    The browser only reads by default, so a stray click in a notebook can't change a production disk. With
    `writable: true`, each file also gets a delete button, and an upload field below the table writes into the current
    directory.

    It lists the directory when it's shown and when you open another one, so files that other cells write show up
    after a click on Refresh.

    It works the same on every disk. A memory disk uses the store of the process that built the browser, which in
    Livebook is the evaluator of the cell. Livebook evaluates all regular sections in one process, so after
    `Fil.Adapter.Memory.checkout/0` in one cell, a browser in any regular section sees the files. A branching section
    has a process of its own, and needs a `checkout/0` of its own.

    ## Upload

    `upload/3` is a file field that writes each file you pick straight to a directory of the disk:

        Fil.Kino.upload(disk, "reports", accept: [".pdf"])

    Livebook keeps an upload as a file in the notebook's runtime, and the field streams it from there into
    `Fil.write/4`, so large files don't have to fit in memory. The line below the field says what was written, or why
    not. An upload never replaces a file unless you pass `if_exists: :overwrite`.

    ## Smart cell

    With `Fil` and Kino installed, Livebook offers a Fil disk smart cell. It's a form for a Local, S3 or Memory disk
    that generates the `Fil.disk/1` call, such as:

        disk =
          Fil.disk(
            adapter: Fil.Adapter.S3,
            bucket: "reports",
            region: "eu-central-1",
            access_key_id: System.fetch_env!("LB_AWS_ACCESS_KEY_ID"),
            secret_access_key: System.fetch_env!("LB_AWS_SECRET_ACCESS_KEY")
          )

    The S3 credentials are Livebook secrets you pick in the form, so they're never part of the notebook. Without them,
    the disk accesses a public bucket without signing. Empty fields are left out, so the adapter's defaults apply.

    For a memory disk, the cell calls `Fil.Adapter.Memory.checkout/0` first. The store belongs to the evaluator (see
    [Browser](#module-browser) for what that means for sections), and it's gone when the runtime restarts.
    """

    @browser_schema NimbleOptions.new!(
                      max_preview_size: [
                        type: :pos_integer,
                        default: 1024 * 1024,
                        doc: """
                        Files larger than this, in bytes, get no preview, only the download button. 1 MiB by default.
                        The size comes from the listing, so nothing is read to decide, and a file that grew since isn't
                        caught.
                        """
                      ],
                      max_download_size: [
                        type: :pos_integer,
                        default: 100 * 1024 * 1024,
                        doc: """
                        Files larger than this, in bytes, can't be downloaded from the browser. 100 MiB by default. A
                        download reads the whole file into memory and sends it to the browser through Livebook, so
                        large files are better copied with `Fil.cp/3` or read with `Fil.stream/3`. The size is checked
                        against the listing, so a file that grew since isn't caught.
                        """
                      ],
                      writable: [
                        type: :boolean,
                        default: false,
                        doc: """
                        Adds a delete button to each file, and an upload field for the current directory below the
                        browser (see `upload/3`). A delete asks for confirmation first, and only deletes files, never
                        directories. The upload never replaces a file.
                        """
                      ]
                    )

    @upload_schema NimbleOptions.new!(
                     label: [
                       type: :string,
                       doc: ~S"""
                       The label of the field. `"Upload to memory:reports"` for a memory disk and the path
                       `"reports"`, by default.
                       """
                     ],
                     accept: [
                       type: {:or, [{:in, [:any]}, {:list, :string}]},
                       default: :any,
                       doc: """
                       The file types the field accepts, as a list of extensions (`".pdf"`) or MIME types
                       (`"image/*"`), or `:any`. Passed to `Kino.Input.file/2`, which raises on an empty list.
                       """
                     ],
                     if_exists: [
                       type: {:in, [:error, :overwrite]},
                       default: :error,
                       doc: """
                       What to do when the directory already has a file of that name. `:error` keeps the file and
                       shows a `Fil.AlreadyExistsError`, `:overwrite` replaces it. See `Fil.write/4`.
                       """
                     ],
                     on_upload: [
                       type: {:fun, 1},
                       doc: """
                       Called with the `Fil.Ref` of each file after it was written, for example to process it. It
                       runs in a process Kino starts for the field.
                       """
                     ]
                   )

    @doc """
    Returns a file browser for a disk or a ref, starting at the root or at `path`.

        Fil.Kino.browser(disk)
        Fil.Kino.browser(disk, "reports")
        Fil.Kino.browser(disk, "reports", writable: true)
        Fil.Kino.browser(reports)
        Fil.Kino.browser(reports, max_download_size: 1_000_000_000)

    It's a `Kino.JS.Live`, and with `writable: true` a `Kino.Layout` of the browser and the upload field. Both render as
    the result of a cell, with `Kino.render/1` and inside a `Kino.Layout` or a `Kino.Frame`. Building the browser does
    no I/O: the directory is listed when the browser is shown, and a storage error shows up in the browser instead of
    raising.

    ## Options

    #{NimbleOptions.docs(@browser_schema)}
    """
    @spec browser(Fil.Disk.t() | Fil.Ref.t()) :: Kino.JS.Live.t()
    def browser(%Fil.Disk{} = disk), do: browser(Fil.ref(disk, "."), [])
    def browser(%Fil.Ref{} = ref), do: browser(ref, [])

    @doc "Returns a file browser. See `browser/1`."
    @spec browser(Fil.Disk.t(), Path.t()) :: Kino.JS.Live.t()
    @spec browser(Fil.Ref.t(), keyword()) :: Kino.JS.Live.t() | Kino.Layout.t()
    def browser(%Fil.Disk{} = disk, path) when is_binary(path), do: browser(Fil.ref(disk, path), [])

    def browser(%Fil.Ref{} = ref, opts) when is_list(opts) do
      opts = validate!(opts, @browser_schema)
      browser = Kino.JS.Live.new(Fil.Kino.Browser, {ref.disk, ref.path, opts, self()})

      if opts[:writable] do
        # The field writes into the directory the browser shows at the time of the upload, and then has the browser
        # list it again.
        upload_opts = [
          label: "Upload to the current directory",
          accept: :any,
          if_exists: :error,
          on_upload: fn _ref -> Kino.JS.Live.cast(browser, :refresh) end
        ]

        dir = fn -> Kino.JS.Live.call(browser, :path, :infinity) end
        upload = Fil.Kino.Upload.new(ref.disk, dir, upload_opts, self())
        Kino.Layout.grid([browser, upload])
      else
        browser
      end
    end

    @doc "Returns a file browser. See `browser/1`."
    @spec browser(Fil.Disk.t(), Path.t(), keyword()) :: Kino.JS.Live.t() | Kino.Layout.t()
    def browser(%Fil.Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
      browser(Fil.ref(disk, path), opts)
    end

    @doc """
    Returns a file field that writes each uploaded file to the root of a disk, or to `path`.

        Fil.Kino.upload(disk)
        Fil.Kino.upload(disk, "reports", accept: [".pdf"], on_upload: &IO.inspect/1)
        Fil.Kino.upload(reports)
        Fil.Kino.upload(reports, if_exists: :overwrite)

    A file is written under the name it had on your computer. A name that isn't a plain file name, such as `..` or one
    with a `/` or a `\\`, is refused. It returns a `Kino.Layout` of Kino's file input and a status line, which renders
    as the result of a cell. The field stays usable after an error.

    ## Options

    #{NimbleOptions.docs(@upload_schema)}
    """
    @spec upload(Fil.Disk.t() | Fil.Ref.t()) :: Kino.Layout.t()
    def upload(%Fil.Disk{} = disk), do: upload(Fil.ref(disk, "."), [])
    def upload(%Fil.Ref{} = ref), do: upload(ref, [])

    @doc "Returns a file field that writes to a disk. See `upload/1`."
    @spec upload(Fil.Disk.t(), Path.t()) :: Kino.Layout.t()
    @spec upload(Fil.Ref.t(), keyword()) :: Kino.Layout.t()
    def upload(%Fil.Disk{} = disk, path) when is_binary(path), do: upload(Fil.ref(disk, path), [])

    def upload(%Fil.Ref{} = ref, opts) when is_list(opts) do
      opts =
        opts
        |> validate!(@upload_schema)
        |> Keyword.put_new_lazy(:label, fn -> default_label(ref) end)

      Fil.Kino.Upload.new(ref.disk, ref.path, opts, self())
    end

    @doc "Returns a file field that writes to a disk. See `upload/1`."
    @spec upload(Fil.Disk.t(), Path.t(), keyword()) :: Kino.Layout.t()
    def upload(%Fil.Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
      upload(Fil.ref(disk, path), opts)
    end

    defp default_label(%Fil.Ref{disk: disk, path: "."}), do: "Upload to #{Fil.Disk.label(disk)}"
    defp default_label(%Fil.Ref{disk: disk, path: path}), do: "Upload to #{Fil.Disk.label(disk)}:#{path}"

    defp validate!(opts, schema) do
      case NimbleOptions.validate(opts, schema) do
        {:ok, validated} -> validated
        {:error, error} -> raise ArgumentError, Exception.message(error)
      end
    end
  end
end
