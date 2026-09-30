defmodule Fil.LiveViewHelper do
  @moduledoc false

  # Uploads through `Fil.LiveViewTest.UploadLive` for `Fil.LiveView`'s tests: the test mounts the LiveView with the
  # upload options and a function the "save" event calls with the socket, uploads files through the channel and
  # submits the form.

  alias Fil.LiveViewTest.UploadLive

  import ExUnit.Assertions
  import Phoenix.ConnTest, only: [build_conn: 0]
  import Phoenix.LiveViewTest

  @endpoint Fil.LiveViewTest.Endpoint

  @doc "Mounts `UploadLive` with the upload options, and a function the \"save\" event calls with the socket."
  @spec mount_upload(keyword(), (Phoenix.LiveView.Socket.t() -> term())) :: term()
  def mount_upload(allow, consume) do
    config = %{test: self(), name: :avatar, allow: allow, consume: consume}
    agent = ExUnit.Callbacks.start_supervised!({Agent, fn -> config end}, id: make_ref())
    {:ok, view, _html} = live_isolated(build_conn(), UploadLive, session: %{"config" => agent})
    view
  end

  @doc "Uploads the files through the channel, submits the form and returns what the consume function returned."
  @spec upload([map()], keyword(), (Phoenix.LiveView.Socket.t() -> term())) :: term()
  def upload(files, allow, consume) do
    view = mount_upload(allow, consume)
    select_and_upload(view, files)
    submit(view)
  end

  @doc "Selects the files in the file input and uploads them through the channel."
  @spec select_and_upload(term(), [map()]) :: term()
  def select_and_upload(view, files) do
    input = file_input(view, "#form", :avatar, Enum.map(files, &file/1))

    for file <- files do
      render_upload(input, file.name)
    end

    input
  end

  @doc "Submits the form and returns what the consume function returned."
  @spec submit(term()) :: term()
  def submit(view) do
    view
    |> element("#form")
    |> render_submit()

    assert_receive {:consumed, result}
    result
  end

  @doc "A text file for each name, with the content `\"content of <name>\"`."
  @spec files([String.t()]) :: [map()]
  def files(names), do: Enum.map(names, &%{name: &1, content: "content of #{&1}"})

  @doc "The entry's file name, as a `path:` function."
  @spec client_name(Phoenix.LiveView.UploadEntry.t()) :: String.t()
  def client_name(entry), do: entry.client_name

  @doc "Consumes the entries of `:avatar` at their file names."
  @spec consume_by_name(Phoenix.LiveView.Socket.t(), term(), keyword()) :: term()
  def consume_by_name(socket, disk, opts \\ []) do
    Fil.LiveView.consume_uploaded_entries(socket, :avatar, disk, [path: &client_name/1] ++ opts)
  end

  @doc "A socket with the upload `:avatar`, for calling the function of `external/2` without a LiveView."
  @spec socket(keyword()) :: Phoenix.LiveView.Socket.t()
  def socket(allow \\ [accept: :any]) do
    Phoenix.LiveView.allow_upload(%Phoenix.LiveView.Socket{}, :avatar, allow)
  end

  @doc "The meta `external/2` returns for a direct upload to `path`, signed at `signed_at` (Unix seconds)."
  @spec direct_meta(String.t(), integer()) :: map()
  def direct_meta(path, signed_at \\ System.os_time(:second)) do
    %{uploader: "Fil", path: path, url: "http://localhost/storage/#{path}", headers: %{}, signed_at: signed_at}
  end

  @doc """
  Mounts `UploadLive` with a direct upload to `disk`. The external function sends the meta to the test, which plays the
  browser: `render_upload/3` only reports progress, and the test PUTs the file itself with `put_direct/3`.
  """
  @spec mount_direct(Fil.Disk.t(), keyword(), (Phoenix.LiveView.Socket.t() -> term())) :: term()
  def mount_direct(disk, allow, consume) do
    test = self()

    external = fn entry, socket ->
      result = Fil.LiveView.external(disk).(entry, socket)
      send(test, {:external, entry.client_name, result})
      result
    end

    mount_upload([external: external] ++ allow, consume)
  end

  @doc "Selects and uploads the files of a direct upload, and returns their metas."
  @spec select_direct(term(), [map()] | map()) :: [map()] | map()
  def select_direct(view, files) when is_list(files) do
    select_and_upload(view, files)

    for file <- files do
      assert_receive {:external, name, {:ok, meta, _socket}} when name == file.name
      meta
    end
  end

  def select_direct(view, file) do
    [meta] = select_direct(view, [file])
    meta
  end

  @doc "Sends the upload the way the browser does, with the meta's headers and the length of the body."
  @spec put_direct(map(), binary(), Fil.Disk.t()) :: Plug.Conn.t()
  def put_direct(meta, body, disk) do
    length =
      body
      |> byte_size()
      |> Integer.to_string()

    headers =
      meta.headers
      |> Map.put("content-length", length)
      |> Map.to_list()

    opts = Fil.Plug.init(at: "/storage", disk: disk)

    meta.url
    |> Fil.PlugHelper.put(body, headers)
    |> Fil.Plug.call(opts)
  end

  defp file(file), do: Map.put_new(file, :type, MIME.from_path(file.name))
end
