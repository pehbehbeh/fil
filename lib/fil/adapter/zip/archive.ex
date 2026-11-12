defmodule Fil.Adapter.Zip.Archive do
  @moduledoc false

  # The bytes of the archive, read through `Fil` from the disk the archive is on, so it can be on any disk and that
  # disk's plugins run.
  #
  # An error from the archive's disk names the archive's path and disk, while the caller asked the zip disk for an
  # entry. So it comes back as a struct of the same kind with the archive's error as its `:reason` and no context of its
  # own, and `Fil.Op` fills in the zip disk's operation, path and disk. A missing archive is a
  # `Fil.ConfigurationError`, because no entry can be found until the `archive:` option changes.

  @doc "The size of the archive."
  @spec size(Fil.Ref.t()) :: {:ok, non_neg_integer()} | {:error, Fil.error()}
  def size(archive) do
    case Fil.stat(archive, type: :regular) do
      {:ok, %Fil.Stat{size: size}} when is_integer(size) -> {:ok, size}
      {:ok, %Fil.Stat{}} -> {:error, bad_archive(:no_size)}
      {:error, error} -> {:error, error(error)}
    end
  end

  @doc "`length` bytes from `offset` on. Fewer bytes mean the archive is shorter than its directory says."
  @spec read(Fil.Ref.t(), non_neg_integer(), non_neg_integer()) :: {:ok, binary()} | {:error, Fil.error()}
  def read(_archive, _offset, 0), do: {:ok, ""}

  def read(archive, offset, length) do
    case Fil.read(archive, offset: offset, length: length) do
      {:ok, bytes} when byte_size(bytes) == length -> {:ok, bytes}
      {:ok, _short} -> {:error, bad_archive(:truncated)}
      {:error, error} -> {:error, error(error)}
    end
  end

  @doc """
  A lazy stream of `length` bytes from `offset` on. It opens the archive's stream each time it's enumerated, and raises
  the archive's errors as `error/1` returns them.
  """
  @spec stream(Fil.Ref.t(), non_neg_integer(), non_neg_integer()) :: Enumerable.t()
  def stream(_archive, _offset, 0), do: []

  def stream(archive, offset, length) do
    archive
    |> resource(offset, length)
    |> Stream.map(&raise_failed!/1)
  end

  # A step that fails hands its error on as an element and ends the resource, so the archive's stream, which cleaned up
  # when it raised, isn't halted a second time. The error is raised after the resource, from `raise_failed!/1`.
  defp resource(archive, offset, length) do
    Stream.resource(fn -> open!(archive, offset, length) end, &next/1, &close/1)
  end

  defp raise_failed!({__MODULE__, :failed, error, stacktrace}), do: reraise(error, stacktrace)
  defp raise_failed!(chunk), do: chunk

  # The archive's stream is enumerated one chunk at a time, so each step can turn its errors into the zip disk's.
  defp open!(archive, offset, length) do
    case Fil.stream(archive, offset: offset, length: length) do
      {:ok, stream} -> &Enumerable.reduce(stream, &1, fn chunk, _acc -> {:suspend, chunk} end)
      {:error, error} -> raise error(error)
    end
  end

  defp next(nil), do: {:halt, nil}

  defp next(continuation) do
    case continuation.({:cont, nil}) do
      {:suspended, chunk, continuation} -> {[chunk], continuation}
      {_done_or_halted, _acc} -> {:halt, nil}
    end
  rescue
    error -> {[{__MODULE__, :failed, error(error), __STACKTRACE__}], nil}
  end

  defp close(nil), do: :ok

  defp close(continuation) do
    continuation.({:halt, nil})
    :ok
  end

  @doc """
  The error for the zip disk's caller, from an error of the archive's disk. Exceptions without `Fil`'s fields, such as a
  plugin's own, are returned as they are.
  """
  @spec error(Exception.t()) :: Exception.t()
  def error(%Fil.NotFoundError{} = error), do: %Fil.ConfigurationError{reason: error}

  def error(%{__exception__: true, op: _, path: _, disk: _, reason: _} = error),
    do: %{error | op: nil, path: nil, disk: nil, reason: error}

  def error(other), do: other

  @doc "The error for an archive that isn't a zip archive, or is damaged: `reason` says where."
  @spec bad_archive(atom()) :: Fil.ConfigurationError.t()
  def bad_archive(reason), do: %Fil.ConfigurationError{reason: {:bad_archive, reason}}
end
