defmodule Fil.Tmp do
  @moduledoc """
  Temporary files and directories, which are removed when the process that created them exits.

  `Fil.tmp/0` creates a directory and `Fil.tmp/1` a file name in a directory of its own. Both return a plain `Fil.Ref`
  on a local disk rooted at that directory, so the whole API works on it:

      report = Fil.tmp("report.pdf")
      {:ok, _} = Fil.cp(Fil.ref(invoices, "2026/09.pdf"), report)
      {text, 0} = System.cmd("pdftotext", [Fil.Tmp.path(report), "-"])

  `path/1` returns the absolute path of a ref on a temporary directory, for tools that need one. A tool can write into
  the directory too, and `Fil` lists what it wrote:

      frames = Fil.tmp()
      {_, 0} = System.cmd("ffmpeg", ["-i", Fil.Tmp.path(video), Fil.Tmp.path(frames.disk, "%03d.png")])
      {:ok, pngs} = Fil.ls(frames)

  Files in the directory are refs on its disk, such as `Fil.ref(frames.disk, "001.png")`.

  ## The directory

  Each call creates a new directory in `System.tmp_dir!/0` (which checks the `TMPDIR`, `TMP` and `TEMP` environment
  variables), named `fil-` and a random suffix. Only the operating system user that runs the node can open it (mode
  `0o700`), because a copy from a disk with an encryption plugin is plaintext here. On Windows the mode does nothing.

  The name passed to `Fil.tmp/1` is used as it is, so tools, mail attachments and `Fil.Plugin.ContentType` see the real
  file name. It can have directories (`"pages/1.png"`), but it has to stay inside the directory: an absolute path, `""`,
  `"."` or a name that escapes with `..` raises `ArgumentError`. Pass a name from user input, such as `upload.filename`,
  through `Path.basename/1` first.

  ## Cleanup

  The directory belongs to the process that called `Fil.tmp/0,1`. It's removed with everything in it when that process
  exits, also when it's killed, by a process of the `:fil` application. So:

    * a temporary file created inside a `Task` is gone when the task returns. Create it in the caller and pass it in, or
      hand it to the caller with `give_away/2`.
    * a long-lived process (a GenServer, a LiveView, a channel) keeps its temporary files for as long as it runs. Call
      `cleanup/1` once it's done with them. A write to a temporary ref after that creates an ordinary directory, with
      the default mode, which `Fil` doesn't remove.
    * `Fil.rm_rf/1` on the directory removes it, but it stays registered to its owner, and a later write creates it
      again without the `0o700` mode. `cleanup/1` removes both.
    * a temporary ref works only on the node that created it.
    * stopping the `:fil` application removes every temporary directory. A crash of the whole node (`kill -9`, a power
      loss) leaves them behind in the system's temporary directory.

  `Fil.tmp/0,1` raises when the `:fil` application isn't running, because nothing would remove the directory then.
  """

  alias Fil.Adapter.Local
  alias Fil.Disk
  alias Fil.Ref
  alias Fil.Support.Tmp
  alias Fil.Support.Unique

  # How many names `new/0,1` tries when a directory with the name exists already.
  @attempts 3

  @doc """
  Creates a temporary directory and returns a ref to it, with path `"."`. `Fil.tmp/0` is the same function.

      iex> Fil.Tmp.new()
      #Fil.Ref<local:.>

  When the directory can't be created, it raises the error struct `Fil.Adapter.Local` would return, such as a
  `Fil.AccessDeniedError` or a `Fil.StorageFullError`, with the directory as `:path`. Without the `:fil` application
  running, it raises a `RuntimeError`.
  """
  @spec new() :: Ref.t()
  def new do
    disk = create_disk()
    Ref.new(disk, ".")
  end

  @doc """
  Creates a temporary directory and returns a ref to the file `name` in it. The file doesn't exist until something
  writes it. `Fil.tmp/1` is the same function.

      iex> Fil.Tmp.new("pages/1.png")
      #Fil.Ref<local:pages/1.png>

  The name has to be a relative path that stays inside the directory (see "The directory" above). Anything else raises
  `ArgumentError` before a directory is created. Otherwise it raises like `new/0`.
  """
  @spec new(Path.t()) :: Ref.t()
  def new(name) when is_binary(name) do
    path = name!(name)
    disk = create_disk()
    Ref.new(disk, path)
  end

  @doc """
  Returns the absolute path of a ref on a temporary directory: of the directory itself, a file in it or anything else
  on its disk.

  It raises `ArgumentError` for a ref on another disk, and after `cleanup/1` or the owner's exit.
  """
  @spec path(Ref.t()) :: Path.t()
  def path(%Ref{disk: disk, path: path}) do
    root = root!(disk)

    case Fil.Support.Path.normalize(path) do
      {:ok, "."} -> root
      {:ok, normalized} -> Path.join(root, normalized)
      {:error, :ebadpath} -> raise ArgumentError, "#{inspect(path)} is outside the temporary directory"
    end
  end

  @doc "Returns the absolute path of `path` on a temporary directory's disk. See `path/1`."
  @spec path(Disk.t(), Path.t()) :: Path.t()
  def path(%Disk{} = disk, path) when is_binary(path) do
    disk
    |> Ref.new(path)
    |> path()
  end

  @doc """
  Makes `pid` the owner of a temporary directory, so it's removed when `pid` exits instead of the calling process. The
  ref can name the directory or anything in it. Returns `:ok`.

      report = Fil.tmp("report.pdf")
      Fil.write!(report, pdf)
      :ok = Fil.Tmp.give_away(report, caller)

  If `pid` is dead already, the directory is removed right away. It raises `ArgumentError` when the calling process
  doesn't own the directory, and for a `pid` on another node.
  """
  @spec give_away(Ref.t(), pid()) :: :ok
  def give_away(%Ref{disk: disk}, pid) when is_pid(pid) do
    if node(pid) != node() do
      raise ArgumentError, "can't give a temporary directory to #{inspect(pid)}, it only exists on #{inspect(node())}"
    end

    root = root!(disk)

    case Tmp.give_away({:tmp, root}, pid) do
      :ok -> :ok
      :error -> raise ArgumentError, "#{inspect(self())} can't give away a temporary directory it doesn't own"
    end
  end

  @doc """
  Removes the temporary directories of `pid` now. Returns `:ok`.

  For processes that run long after they're done with their temporary files. It never fails: a directory that can't
  be removed completely is left as it is. It leaves the temporary files of `Fil.Adapter.Local` writes in progress
  alone, so a write of `pid` still works.

  Don't use the refs afterwards. A write to one creates an ordinary directory in its place, with the default mode,
  which `Fil` doesn't remove.
  """
  @spec cleanup(pid()) :: :ok
  def cleanup(pid \\ self()) when is_pid(pid), do: Tmp.remove_tmp(pid)

  defp name!(name) do
    normalized = if Path.type(name) == :relative, do: Fil.Support.Path.normalize(name), else: {:error, :absolute}

    case normalized do
      {:ok, path} when path != "." ->
        path

      _invalid ->
        raise ArgumentError,
              "expected a relative path inside the temporary directory as the name, got: #{inspect(name)}. " <>
                "Pass names from user input through Path.basename/1"
    end
  end

  defp create_disk do
    if !Tmp.available?() do
      raise "Fil.tmp/0,1 needs the :fil application, which removes temporary directories when their owner exits, " <>
              "but it isn't running. Start it with Application.ensure_all_started(:fil)"
    end

    System.tmp_dir!()
    |> create_dir(@attempts)
    |> disk()
  end

  # The entry comes before the directory, so an owner that's killed during `mkdir` leaves nothing behind. The directory
  # is empty until the `chmod`, so nobody can read anything in it before.
  #
  # The `:eexist` retry, a failed `mkdir` and a failed `chmod` have no tests: `System.tmp_dir!/0` only returns a
  # writable directory, and the names are random, so none of them is easy to provoke.
  defp create_dir(parent, attempts) do
    dir =
      parent
      |> Path.join("fil-" <> Unique.name())
      |> Path.expand()

    key = {:tmp, dir}
    :ok = Tmp.put(key, nil)

    case File.mkdir(dir) do
      :ok ->
        restrict(dir, key)

      # Someone else's directory, which the owner mustn't remove.
      {:error, :eexist} when attempts > 1 ->
        Tmp.delete(key)
        create_dir(parent, attempts - 1)

      {:error, reason} ->
        Tmp.delete(key)
        raise error(reason, dir)
    end
  end

  defp restrict(dir, key) do
    case File.chmod(dir, 0o700) do
      :ok ->
        dir

      {:error, reason} ->
        _result = File.rmdir(dir)
        Tmp.delete(key)
        raise error(reason, dir)
    end
  end

  defp error(reason, dir) do
    struct = Local.to_struct(reason)
    %{struct | path: dir}
  end

  defp disk(root), do: Fil.disk(adapter: Local, root: root)

  defp root!(%Disk{adapter: {Local, %Local{root: root}}} = disk) do
    if Tmp.member?({:tmp, root}), do: root, else: not_tmp!(disk)
  end

  defp root!(disk), do: not_tmp!(disk)

  defp not_tmp!(disk) do
    raise ArgumentError,
          "expected a ref on a temporary directory from Fil.tmp/0,1, got one on #{inspect(disk)}, which isn't one " <>
            "or was removed already"
  end
end
