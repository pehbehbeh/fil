if Code.ensure_loaded?(Kino.JS.Live) do
  defmodule Fil.Kino do
    @moduledoc """
    Browses disks in [Livebook](https://livebook.dev).

        Mix.install([{:fil, "~> 0.2"}, {:kino, "~> 0.19"}])

        disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
        Fil.Kino.browser(disk)

    Needs [Kino](https://hexdocs.pm/kino), an optional dependency of `Fil`.

    ## Browser

    `browser/3` shows one directory of a disk at a time: breadcrumbs back to the root, and a table with the name, size,
    modification time and type of each entry. Clicking a directory opens it. Clicking a file shows a preview below the
    table, for images (PNG, JPEG, GIF and WebP) and text, and each file has a download button. The browser only reads.

    It lists the directory when it's shown and when you open another one, so files that other cells write show up
    after a click on Refresh.

    It works the same on every disk. A memory disk uses the store of the process that built the browser, which in
    Livebook is the evaluator of the cell. Livebook evaluates all regular sections in one process, so after
    `Fil.Adapter.Memory.checkout/0` in one cell, a browser in any regular section sees the files. A branching section
    has a process of its own, and needs a `checkout/0` of its own.
    """

    @browser_schema NimbleOptions.new!(
                      max_preview_size: [
                        type: :pos_integer,
                        default: 1024 * 1024,
                        doc: """
                        Files larger than this, in bytes, get no preview, only the download button. 1 MiB by default.
                        The size comes from the listing, so nothing is read to decide.
                        """
                      ],
                      max_download_size: [
                        type: :pos_integer,
                        default: 100 * 1024 * 1024,
                        doc: """
                        Files larger than this, in bytes, can't be downloaded from the browser. 100 MiB by default. A
                        download reads the whole file into memory and sends it to the browser through Livebook, so
                        large files are better copied with `Fil.cp/3` or read with `Fil.stream/3`.
                        """
                      ]
                    )

    @doc """
    Returns a file browser for a disk or a ref, starting at the root or at `path`.

        Fil.Kino.browser(disk)
        Fil.Kino.browser(disk, "reports")
        Fil.Kino.browser(disk, "reports", max_preview_size: 10_000_000)
        Fil.Kino.browser(reports)
        Fil.Kino.browser(reports, max_download_size: 1_000_000_000)

    It's a `Kino.JS.Live`, so it renders as the result of a cell, with `Kino.render/1` and inside a `Kino.Layout` or a
    `Kino.Frame`. Building it does no I/O: the directory is listed when the browser is shown, and a storage error
    shows up in the browser instead of raising.

    ## Options

    #{NimbleOptions.docs(@browser_schema)}
    """
    @spec browser(Fil.Disk.t() | Fil.Ref.t()) :: Kino.JS.Live.t()
    def browser(%Fil.Disk{} = disk), do: browser(Fil.ref(disk, "."), [])
    def browser(%Fil.Ref{} = ref), do: browser(ref, [])

    @doc "Returns a file browser. See `browser/1`."
    @spec browser(Fil.Disk.t(), Path.t()) :: Kino.JS.Live.t()
    @spec browser(Fil.Ref.t(), keyword()) :: Kino.JS.Live.t()
    def browser(%Fil.Disk{} = disk, path) when is_binary(path), do: browser(Fil.ref(disk, path), [])

    def browser(%Fil.Ref{} = ref, opts) when is_list(opts) do
      opts = validate!(opts, @browser_schema)

      Kino.JS.Live.new(Fil.Kino.Browser, {ref.disk, ref.path, opts, self()})
    end

    @doc "Returns a file browser. See `browser/1`."
    @spec browser(Fil.Disk.t(), Path.t(), keyword()) :: Kino.JS.Live.t()
    def browser(%Fil.Disk{} = disk, path, opts) when is_binary(path) and is_list(opts) do
      browser(Fil.ref(disk, path), opts)
    end

    defp validate!(opts, schema) do
      case NimbleOptions.validate(opts, schema) do
        {:ok, validated} -> validated
        {:error, error} -> raise ArgumentError, Exception.message(error)
      end
    end
  end
end
