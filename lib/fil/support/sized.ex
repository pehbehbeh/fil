defmodule Fil.Support.Sized do
  @moduledoc false

  # A stream from an adapter whose size the adapter found when it checked the file. The size belongs to this stream
  # only: a plugin that transforms the content builds a new stream, which has no size, so it can't go stale.
  # `Fil.write/4` sends it with its size, so storage that needs the size up front (S3) can stream. `:context` is the
  # context of the read (`Fil.Support.Content.put_context/3`), for the error when the file changes size meanwhile.

  @enforce_keys [:stream, :size]
  defstruct [:stream, :size, context: []]

  @type t :: %__MODULE__{stream: Enumerable.t(), size: non_neg_integer(), context: keyword()}

  defimpl Enumerable do
    def reduce(%{stream: stream}, acc, fun), do: Enumerable.reduce(stream, acc, fun)
    def count(_sized), do: {:error, __MODULE__}
    def member?(_sized, _element), do: {:error, __MODULE__}
    def slice(_sized), do: {:error, __MODULE__}
  end
end
