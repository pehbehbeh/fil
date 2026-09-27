defmodule Fil.Adapter.Local do
  @schema NimbleOptions.new!(
            root: [
              type: :string,
              doc: """
              The directory every path is resolved against. Defaults to `File.cwd!()` when the disk is built, so
              changing the working directory later doesn't move the disk. A relative root is expanded once, when the
              disk is built.
              """
            ]
          )

  @moduledoc """
  The local filesystem, jailed under a root directory.

      disk = Fil.disk(adapter: Fil.Adapter.Local, root: "priv/storage")

  ## Behaviour

    * writes are atomic: content goes to a temporary file in the destination directory and is then renamed into place,
      so readers never see a partial file. Missing parent directories are created first.
    * `if_exists: :error` skips the temporary file and opens the destination with `O_EXCL` instead. If something is
      already there, the write returns a `Fil.AlreadyExistsError`.
    * every path is checked against the root again after expansion. `Fil` has already rejected `../` escapes, so this is
      defense in depth. The check only looks at the path string: a symlink inside the root can still point outside it.
    * listing a missing directory, or a path that isn't a directory, returns `{:ok, []}`, the same as a missing prefix
      on an object store.
    * `stat/3` sets `:etag` to a weak `"size-mtime"` tag. It's good enough to notice a change, but it can't prove there
      was none. `:content_type` is always `nil`, because the filesystem doesn't store one.
    * the filesystem has no URLs. Attach `Fil.Plugin.URL` for public and signed URLs, and `Fil.Plug` serves them.
    * the filesystem stores no checksums. `checksum:` on a write is accepted and ignored, and so is
      `verify_checksum: true` on a read. `checksum:` on a stat reads the whole file to compute it.

  ## Options

  #{NimbleOptions.docs(@schema)}

  ## Operations

  | `Fil` | Local |
  | --- | --- |
  | `read/3` | `File.read/1` |
  | `write/4` | temporary file, then `File.rename/2` (`:file.open/2` with `:exclusive` for `if_exists: :error`) |
  | `rm/3` | `File.rm/1`, a missing file mapped to success |
  | `stat/3` | `File.stat/2`, plus a pass over the file for `checksum:` |
  | `ls/3` | `File.ls/1`, walked depth-first when recursive |
  | `cp/4` | `File.cp/2` |
  | `rename/4` | `File.rename/2` |
  | `rm_rf/3` | `File.rm_rf/1`, counting the files it removed |

  ## Errors

  `:reason` is the POSIX atom from `File`, adjusted so it's the same on macOS and Linux (deleting a directory is
  `:eisdir` on both, a parent that's a file `:enotdir`).

  | Situation | `Fil` error | `:reason` |
  | --- | --- | --- |
  | a missing file or directory, or a path through a file (`report.txt/x`) | `Fil.NotFoundError` | `:enoent` |
  | missing permissions, a read-only filesystem | `Fil.AccessDeniedError` | `:eacces`, `:eperm`, `:erofs` |
  | reading, copying or deleting a directory, or writing over one | `Fil.InvalidRequestError` | `:eisdir` |
  | writing, copying or renaming to a path under a file | `Fil.InvalidRequestError` | `:enotdir` |
  | a name that's too long, a symlink loop | `Fil.InvalidRequestError` | `:enametoolong`, `:eloop` |
  | a path that resolves outside the root | `Fil.InvalidRequestError` | `:ebadpath` |
  | an exclusive create finding the file already there | `Fil.AlreadyExistsError` | `:eexist` |
  | a full disk, a used-up quota | `Fil.StorageFullError` | `:enospc`, `:edquot` |
  | too many open files | `Fil.UnavailableError` | `:emfile`, `:enfile` |
  | any other POSIX error | `Fil.UnknownError` | the atom |
  """

  @behaviour Fil.Adapter

  alias Fil.Stat
  alias Fil.Support.Checksum

  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @impl Fil.Adapter
  def init(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema) do
      root = Keyword.get(opts, :root, File.cwd!())

      {:ok, %__MODULE__{root: Path.expand(root)}}
    end
  end

  # Each callback works with the POSIX atoms from `File` and turns an error into a struct at the end (`to_error/1`).

  @impl Fil.Adapter
  def read(state, path, _opts), do: to_error(read_file(state, path))

  @impl Fil.Adapter
  def write(state, path, content, opts), do: to_error(write_file(state, path, content, opts))

  @impl Fil.Adapter
  def rm(state, path, _opts), do: to_error(rm_file(state, path))

  @impl Fil.Adapter
  def stat(state, path, opts), do: to_error(stat_file(state, path, opts))

  @impl Fil.Adapter
  def ls(state, prefix, opts), do: to_error(list(state, prefix, opts))

  @impl Fil.Adapter
  def cp(state, src, dest, _opts), do: to_error(transfer(&File.cp/2, state, src, dest))

  @impl Fil.Adapter
  def rename(state, src, dest, _opts), do: to_error(transfer(&File.rename/2, state, src, dest))

  @impl Fil.Adapter
  def rm_rf(state, prefix, _opts), do: to_error(rm_tree(state, prefix))

  defp list(state, prefix, opts) do
    with {:ok, full} <- full_path(state, prefix) do
      if Keyword.get(opts, :recursive, false) do
        {:ok, walk(full, prefix)}
      else
        {:ok, one_level(full, prefix)}
      end
    end
  end

  defp read_file(state, path) do
    with {:ok, full} <- full_path(state, path), do: missing(File.read(full))
  end

  defp write_file(state, path, content, opts) do
    with {:ok, full} <- full_path(state, path),
         :ok <- ensure_parent(full) do
      case Keyword.get(opts, :if_exists, :overwrite) do
        :overwrite -> atomic_write(full, content)
        :error -> exclusive_write(full, content)
      end
    end
  end

  defp rm_file(state, path) do
    with {:ok, full} <- full_path(state, path) do
      case File.rm(full) do
        :ok -> :ok
        {:error, reason} when reason in [:enoent, :enotdir] -> :ok
        {:error, :eperm} -> {:error, directory_or(full, :eperm)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp stat_file(state, path, opts) do
    with {:ok, full} <- full_path(state, path),
         {:ok, stat} <- missing(File.stat(full, time: :posix)) do
      put_checksum(to_stat(stat), full, Keyword.get(opts, :checksum))
    end
  end

  # A destination under a file fails on the destination side, so the error has that path.
  defp transfer(fun, state, src, dest) do
    with {:ok, from} <- full_path(state, src),
         {:ok, to} <- full_path(state, dest) do
      case ensure_parent(to) do
        :ok -> missing(fun.(from, to))
        {:error, reason} -> {:error, %{to_struct(reason) | path: dest}}
      end
    end
  end

  defp rm_tree(state, prefix) do
    with {:ok, full} <- full_path(state, prefix) do
      count = count_files(full)

      case File.rm_rf(full) do
        {:ok, _removed} -> {:ok, count}
        {:error, reason, _path} -> {:error, reason}
      end
    end
  end

  ## ------------------------------------------------------------------
  ## Errors
  ## ------------------------------------------------------------------

  defp to_error({:error, reason}) when is_atom(reason), do: {:error, to_struct(reason)}
  defp to_error(result), do: result

  defp to_struct(:enoent), do: %Fil.NotFoundError{reason: :enoent}

  defp to_struct(reason) when reason in [:eacces, :eperm, :erofs], do: %Fil.AccessDeniedError{reason: reason}

  defp to_struct(reason) when reason in [:eisdir, :enotdir, :enametoolong, :eloop, :ebadpath],
    do: %Fil.InvalidRequestError{reason: reason}

  defp to_struct(:eexist), do: %Fil.AlreadyExistsError{reason: :eexist}
  defp to_struct(reason) when reason in [:enospc, :edquot], do: %Fil.StorageFullError{reason: reason}
  defp to_struct(reason) when reason in [:emfile, :enfile], do: %Fil.UnavailableError{reason: reason}
  defp to_struct(reason), do: %Fil.UnknownError{reason: reason}

  ## ------------------------------------------------------------------
  ## Paths
  ## ------------------------------------------------------------------

  defp full_path(%__MODULE__{root: root}, ".") do
    {:ok, root}
  end

  defp full_path(%__MODULE__{root: root}, path) do
    full =
      root
      |> Path.join(path)
      |> Path.expand()

    if full == root or String.starts_with?(full, root <> "/") do
      {:ok, full}
    else
      {:error, :ebadpath}
    end
  end

  # A parent that's a file is `:enotdir` on macOS and `:eexist` on Linux.
  defp ensure_parent(full) do
    parent = Path.dirname(full)

    case File.mkdir_p(parent) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  # A path through a file (`report.txt/x`) is `:enotdir` to the filesystem, but that file doesn't exist, which
  # is what an object store says too. `cp/4` and `rename/4` call it after `ensure_parent/1`, so there it can only be the
  # source, and a destination under a file stays `:enotdir`.
  defp missing({:error, :enotdir}), do: {:error, :enoent}
  defp missing(result), do: result

  # Deleting a directory is `:eperm` on macOS and Linux, and an exclusive create on one is `:eexist`. This runs before
  # `to_struct/1`, so a directory is an invalid request, not denied access.
  defp directory_or(full, reason), do: if(File.dir?(full), do: :eisdir, else: reason)

  ## ------------------------------------------------------------------
  ## Writing
  ## ------------------------------------------------------------------

  defp atomic_write(full, content) do
    tmp = full <> ".fil-" <> unique()

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, full) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp exclusive_write(full, content) do
    case :file.open(full, [:write, :exclusive, :binary, :raw]) do
      {:ok, io} ->
        result = :file.write(io, content)
        _ = :file.close(io)

        case result do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :eexist} ->
        {:error, directory_or(full, :eexist)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unique do
    counter =
      [:positive]
      |> System.unique_integer()
      |> Integer.to_string(36)

    time =
      :microsecond
      |> System.system_time()
      |> Integer.to_string(36)

    counter <> "-" <> time
  end

  ## ------------------------------------------------------------------
  ## Listing
  ## ------------------------------------------------------------------

  defp one_level(full, prefix) do
    full
    |> names()
    |> Enum.flat_map(&shallow(full, prefix, &1))
  end

  defp walk(full, prefix) do
    full
    |> names()
    |> Enum.flat_map(&deep(full, prefix, &1))
  end

  # A missing or unreadable directory lists nothing, the same as a prefix nobody wrote to on an object store.
  defp names(full) do
    case File.ls(full) do
      {:ok, names} -> Enum.sort(names)
      {:error, _reason} -> []
    end
  end

  defp shallow(full, prefix, name) do
    case listing(Path.join(full, name), Fil.Support.Path.join(prefix, name)) do
      {:ok, listed} -> [listed]
      :error -> []
    end
  end

  defp deep(full, prefix, name) do
    child_full = Path.join(full, name)
    child_path = Fil.Support.Path.join(prefix, name)

    case listing(child_full, child_path) do
      {:ok, {_path, %Stat{type: :directory}}} -> walk(child_full, child_path)
      {:ok, listed} -> [listed]
      :error -> []
    end
  end

  defp listing(full, path) do
    case File.stat(full, time: :posix) do
      {:ok, %File.Stat{type: type} = stat} when type in [:regular, :directory] ->
        {:ok, {path, to_stat(stat)}}

      _other ->
        :error
    end
  end

  defp count_files(full) do
    case File.stat(full, time: :posix) do
      {:ok, %File.Stat{type: :regular}} ->
        1

      {:ok, %File.Stat{type: :directory}} ->
        full
        |> walk(".")
        |> length()

      _other ->
        0
    end
  end

  ## ------------------------------------------------------------------
  ## Stat
  ## ------------------------------------------------------------------

  defp put_checksum(stat, _full, nil), do: {:ok, stat}
  defp put_checksum(%Stat{type: :directory} = stat, _full, _algorithm), do: {:ok, stat}

  defp put_checksum(stat, full, algorithm) do
    with {:ok, checksum} <- Checksum.digest_file(algorithm, full) do
      {:ok, %{stat | checksum: {algorithm, checksum}}}
    end
  end

  defp to_stat(%File.Stat{type: type, size: size, mtime: mtime}) do
    %Stat{
      size: size,
      type: type,
      mtime: DateTime.from_unix!(mtime),
      etag: "#{size}-#{mtime}",
      content_type: nil
    }
  end
end
