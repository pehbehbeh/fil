defmodule Fil.ReqStub do
  @moduledoc """
  A Req adapter for the cloud unit tests, so they make no network requests.

  Req takes a module with `run/1` as its adapter. It runs the adapter in the test process, after its own request steps,
  so this one calls the function the test stubbed for its own process:

      Fil.ReqStub.stub(fn request -> {request, Req.Response.new(status: 200)} end)
      Fil.disk(adapter: Fil.Adapter.S3, bucket: "bucket", req_options: [adapter: Fil.ReqStub])

  The function returns `{request, response}` or `{request, exception}`, like any Req adapter. Tests stay async, because
  every test process has its own stub.
  """

  @doc "Answers every request of the calling process with `fun`."
  @spec stub((Req.Request.t() -> {Req.Request.t(), Req.Response.t() | Exception.t()})) :: :ok
  def stub(fun) when is_function(fun, 1) do
    Process.put(__MODULE__, fun)
    :ok
  end

  @doc false
  def run(request) do
    case Process.get(__MODULE__) do
      nil -> raise "#{inspect(self())} has no Req stub, call Fil.ReqStub.stub/1 in the test first"
      fun -> fun.(request)
    end
  end
end
