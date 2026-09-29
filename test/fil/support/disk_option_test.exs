defmodule Fil.Support.DiskOptionTest do
  alias Fil.Support.DiskOption

  use ExUnit.Case, async: true

  @schema_all NimbleOptions.new!(disk: [type: DiskOption.type([:disk, :fun, :mfa])])
  @schema_compiled NimbleOptions.new!(disk: [type: DiskOption.type([:remote_fun, :mfa])])

  def uploads, do: Fil.disk(adapter: Fil.Adapter.Memory)

  test "accepts a disk, a function and an MFA" do
    disk = uploads()

    for value <- [disk, fn -> disk end, &__MODULE__.uploads/0, {__MODULE__, :uploads, []}] do
      assert {:ok, [disk: ^value]} = NimbleOptions.validate([disk: value], @schema_all)
    end
  end

  test "accepts only captures of named functions and MFAs with :remote_fun" do
    for value <- [&__MODULE__.uploads/0, {__MODULE__, :uploads, []}] do
      assert {:ok, [disk: ^value]} = NimbleOptions.validate([disk: value], @schema_compiled)
    end

    assert {:error, error} = NimbleOptions.validate([disk: uploads()], @schema_compiled)
    assert Exception.message(error) =~ "expected a capture of a named 0-arity function or"
  end

  test "refuses an anonymous function and a local capture with :remote_fun, and says why" do
    for value <- [fn -> uploads() end, &uploads/0] do
      assert {:error, error} = NimbleOptions.validate([disk: value], @schema_compiled)
      assert Exception.message(error) =~ "got an anonymous function or a local capture. This option ends up in compiled"
      assert Exception.message(error) =~ "such as `&MyApp.Storage.uploads/0`"
    end
  end

  test "refuses functions of another arity and anything else" do
    for value <- [fn _path -> uploads() end, :uploads, {__MODULE__, "uploads", []}, "uploads"] do
      assert {:error, error} = NimbleOptions.validate([disk: value], @schema_all)
      assert Exception.message(error) =~ "expected a `Fil.Disk`, or a 0-arity function or `{module, function, args}`"
    end
  end

  test "documents the forms it allows" do
    assert DiskOption.doc([:disk, :fun, :mfa]) =~
             "A `Fil.Disk`, or a 0-arity function or `{module, function, args}` that returns one. A function is called"

    assert DiskOption.doc([:remote_fun, :mfa]) =~
             "A capture of a named 0-arity function or `{module, function, args}` that returns a `Fil.Disk`."
  end

  test "raises for an unknown form" do
    assert_raise ArgumentError, fn -> DiskOption.type([:disk, :registry]) end
  end
end
