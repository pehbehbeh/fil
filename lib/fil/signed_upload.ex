defmodule Fil.SignedUpload do
  @moduledoc """
  An upload signed with `Fil.signed_upload/3`: the request a client sends to store one file.

    * `:method`: the HTTP method, `:put`
    * `:url`: the signed URL
    * `:headers`: the headers the client has to send along, as a map of lowercase names to values. They differ
      between disks, so pass them on as they are. The body is the file, and its size is the `content-length`, which
      browsers set themselves

  A browser sends it with `fetch`:

      fetch(upload.url, {method: "PUT", headers: upload.headers, body: file})

  """

  @enforce_keys [:url]
  defstruct [:url, method: :put, headers: %{}]

  @type t :: %__MODULE__{method: :put, url: String.t(), headers: %{optional(String.t()) => String.t()}}
end
