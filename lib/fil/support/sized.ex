defmodule Fil.Support.Sized do
  @moduledoc false

  # A stream from an adapter whose size the adapter found when it checked the file. The size belongs to this stream
  # only: a plugin that transforms the content builds a new stream, which has no size, so it can't go stale.
  # `Fil.cp/3` across disks passes it to the write, so storage that needs the size up front (S3) can stream.

  @enforce_keys [:stream, :size]
  defstruct [:stream, :size]

  @type t :: %__MODULE__{stream: Enumerable.t(), size: non_neg_integer()}

  defimpl Enumerable do
    def reduce(%{stream: stream}, acc, fun), do: Enumerable.reduce(stream, acc, fun)
    def count(_sized), do: {:error, __MODULE__}
    def member?(_sized, _element), do: {:error, __MODULE__}
    def slice(_sized), do: {:error, __MODULE__}
  end
end
