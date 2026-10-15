defmodule Fil.SignedUpload do
  @moduledoc """
  An upload signed with `Fil.signed_upload/3`: the request a client sends to store one file.

    * `:method`: the HTTP method, `:put` or `:post`
    * `:url`: the signed URL
    * `:headers`: the headers the client has to send along, as a map of lowercase names to values
    * `:fields`: for `:post`, the form fields that go before the file, as `{name, value}` pairs in the order they're
      sent. The file goes last, as the field `file`. Empty for `:put`
    * `:expires_at`: when the URL stops working, so a client can ask for a new one instead of failing

  Clients have to send exactly what's here: the method, every header and every field. They differ between disks, and
  between versions of an adapter, so a client that assumes a `PUT` breaks on one that signs a form. A `:put` sends the
  file as the body, and its size is the `content-length`, which browsers set themselves. A `:post` sends a
  `multipart/form-data` body.

  A browser sends it with `fetch`:

  ```javascript
  const body = upload.method === "post" ? formData(upload.fields, file) : file
  fetch(upload.url, {method: upload.method.toUpperCase(), headers: upload.headers, body})
  ```

  where `formData` appends each field, then the file as `file`. `Fil.LiveView`'s uploader does this.
  """

  @enforce_keys [:url, :expires_at]
  defstruct [:url, :expires_at, method: :put, headers: %{}, fields: []]

  @type t :: %__MODULE__{
          method: :put | :post,
          url: String.t(),
          headers: %{optional(String.t()) => String.t()},
          fields: [{String.t(), String.t()}],
          expires_at: DateTime.t()
        }
end
