defmodule Fil.KinoHelper do
  @moduledoc false

  # Fakes uploads into a `Kino.Input.file/2`. In Livebook, the input sends a change event with a file ref to Kino's
  # subscription manager, and `Kino.Input.file_path/1` asks the group leader for the file the ref stands for. The group
  # leader of `Kino.Test` can't answer that, so `configure_uploads/1` puts one in front of it that answers from the
  # files `upload/3` registers, and passes every other request on.

  import ExUnit.Assertions

  @doc "A setup callback, after `Kino.Test.configure_livebook_bridge/1`."
  def configure_uploads(_context) do
    kino_group_leader = Process.group_leader()
    group_leader = spawn_link(fn -> loop(kino_group_leader, %{}) end)
    Process.group_leader(self(), group_leader)
    :ok
  end

  @doc "Uploads `content` into `input` under `client_name`, as Livebook does."
  def upload(%Kino.Input{} = input, client_name, content) do
    await_listener(input)

    id =
      [:positive]
      |> System.unique_integer()
      |> Integer.to_string()

    source = Path.join(System.tmp_dir!(), "fil-kino-upload-#{id}")
    File.write!(source, content)
    ExUnit.Callbacks.on_exit(fn -> File.rm(source) end)

    send(Process.group_leader(), {:put_file, {:file, id}, source})

    value = %{file_ref: {:file, id}, client_name: client_name}
    send(Kino.SubscriptionManager, {:event, input.ref, %{type: :change, value: value, origin: "client1"}})
    :ok
  end

  @doc "The input and the status frame of an upload field."
  def upload_field(%Kino.Layout{items: [%Kino.Input{} = input, %Kino.Frame{} = frame]}), do: {input, frame}

  @doc "Returns the next text `frame` shows."
  def status(%Kino.Frame{ref: ref}) do
    assert_receive {:livebook_put_output, %{type: :frame_update, ref: ^ref, update: {:replace, [output]}}}, 1000
    assert %{type: :plain_text, text: text} = output
    text
  end

  # The listener subscribes to the input when it starts, in its own process, so an event sent before that is lost.
  defp await_listener(input, attempts \\ 100) do
    %{topic_with_subscribers: topics} = :sys.get_state(Kino.SubscriptionManager)

    cond do
      Map.has_key?(topics, input.ref) -> :ok
      attempts > 0 -> await_listener_again(input, attempts)
      true -> flunk("the upload field's listener didn't subscribe to its input")
    end
  end

  defp await_listener_again(input, attempts) do
    Process.sleep(5)
    await_listener(input, attempts - 1)
  end

  defp loop(kino_group_leader, files) do
    receive do
      {:put_file, file_ref, path} ->
        loop(kino_group_leader, Map.put(files, file_ref, path))

      {:io_request, from, reply_as, {:livebook_get_file_path, file_ref}} ->
        reply = if path = files[file_ref], do: {:ok, path}, else: {:error, :not_found}
        send(from, {:io_reply, reply_as, reply})
        loop(kino_group_leader, files)

      message ->
        send(kino_group_leader, message)
        loop(kino_group_leader, files)
    end
  end
end
