defmodule Fil.Ref do
  @moduledoc """
  A reference to a file on a disk: a `Fil.Disk` plus a path. It can point to a file that doesn't exist yet, such as the
  destination of a copy.

  Every `Fil` function that can fail accepts a ref in place of a `disk, path` pair, and every action on a file
  returns the resulting ref, so calls chain:

      with {:ok, report} <- Fil.write(disk, "reports/q3.pdf", pdf),
           {:ok, _backup} <- Fil.cp(report, Fil.ref(other_disk, "backups/q3.pdf")) do
        {:ok, report}
      end

  ## The `:stat` field

  `Fil.ls/2` fills in `:stat` from the listing, so you can filter a listing by size and then read, copy or delete the
  same values:

      {:ok, reports} = Fil.ls(disk, "reports")

      reports
      |> Enum.filter(&(&1.stat.type == :regular and &1.stat.size > 1_000_000))
      |> Enum.each(&Fil.rm/1)

  The stat is a snapshot from the time of the listing. Operations ignore it and never treat it as the current state, and
  the refs they return have `stat: nil` instead of a stale value. This means:

    * `stat: nil` says nothing about the file. Call `Fil.stat/1` for the current state.
    * comparing whole structs compares the snapshots too. Compare `:disk` and `:path` to check for the same file.

  ## Inspect

  A ref contains a disk, and a disk may contain credentials, so `Inspect` only prints the adapter label and the
  path:

      iex> Fil.ref(Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil"), "uploads/a.txt")
      #Fil.Ref<local:uploads/a.txt>

  For the same reason, refs aren't meant to be serialized. Store `ref.path` and rebuild the disk instead.
  """

  alias Fil.Disk
  alias Fil.Stat

  @enforce_keys [:disk, :path]
  defstruct [:disk, :path, :stat]

  @type t :: %__MODULE__{disk: Disk.t(), path: String.t(), stat: Stat.t() | nil}

  @doc """
  Builds a ref.

  The path is normalized when possible (see "Concepts" in `Fil`). A path that can't be normalized, such as one that
  escapes the disk root, is kept as given. Using it later returns a `Fil.InvalidRequestError` instead of raising here.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      iex> Fil.Ref.new(disk, "./uploads//a.txt").path
      "uploads/a.txt"
      iex> Fil.Ref.new(disk, "").path
      "."
      iex> escape = Fil.Ref.new(disk, "../escape.txt")
      iex> escape.path
      "../escape.txt"
      iex> {:error, %Fil.InvalidRequestError{reason: :ebadpath}} = Fil.read(escape)

  """
  @spec new(Disk.t(), Path.t()) :: t()
  def new(%Disk{} = disk, path) when is_binary(path) do
    case Fil.Support.Path.normalize(path) do
      {:ok, normalized} -> %__MODULE__{disk: disk, path: normalized}
      {:error, _reason} -> %__MODULE__{disk: disk, path: path}
    end
  end

  @doc """
  Canonicalizes a ref for an operation.

  Normalizes the path, rejects escapes with a `Fil.InvalidRequestError` and drops `:stat`, so a listing snapshot is
  never mistaken for the current state. Every public `Fil` function calls this before the adapter gets the path.

      iex> disk = Fil.disk(adapter: Fil.Adapter.Local, root: "/tmp/fil")
      iex> {:ok, normalized} = Fil.Ref.normalize(%Fil.Ref{disk: disk, path: "a/../b.txt"})
      iex> normalized.path
      "b.txt"
      iex> Fil.Ref.normalize(normalized) == {:ok, normalized}
      true
      iex> {:error, %Fil.InvalidRequestError{path: "../etc/passwd", reason: :ebadpath}} =
      ...>   Fil.Ref.normalize(%Fil.Ref{disk: disk, path: "../etc/passwd"})

  """
  @spec normalize(t()) :: {:ok, t()} | {:error, Fil.InvalidRequestError.t()}
  def normalize(%__MODULE__{disk: %Disk{} = disk, path: path}) when is_binary(path) do
    case Fil.Support.Path.normalize(path) do
      {:ok, normalized} ->
        {:ok, %__MODULE__{disk: disk, path: normalized}}

      {:error, :ebadpath} ->
        {:error, %Fil.InvalidRequestError{path: path, disk: disk, reason: :ebadpath}}
    end
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Fil.Ref{disk: disk, path: path}, _opts) do
      concat(["#Fil.Ref<", Fil.Disk.label(disk), ":", path, ">"])
    end
  end
end
