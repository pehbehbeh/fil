defmodule Fil.Ecto.RefTest.Storage do
  def uploads, do: Fil.disk(adapter: Fil.Adapter.Memory)
  def other, do: Fil.disk(adapter: Fil.Adapter.Memory, root: "other")
end

defmodule Fil.Ecto.RefTest.Photo do
  use Ecto.Schema

  embedded_schema do
    field :file, Fil.Ecto.Ref, disk: &Fil.Ecto.RefTest.Storage.uploads/0
  end
end

defmodule Fil.Ecto.RefTest.User do
  use Ecto.Schema

  schema "users" do
    field :name, :string
    field :avatar, Fil.Ecto.Ref, disk: &Fil.Ecto.RefTest.Storage.uploads/0
    field :photos, {:array, Fil.Ecto.Ref}, disk: {Fil.Ecto.RefTest.Storage, :uploads, []}, default: []
    embeds_many :gallery, Fil.Ecto.RefTest.Photo, on_replace: :delete
  end
end

defmodule Fil.Ecto.RefTest.Repo do
  use Ecto.Repo, otp_app: :fil, adapter: Ecto.Adapters.SQLite3
end

# The SQLite migration from the `Fil.Ecto.Ref` docs.
defmodule Fil.Ecto.RefTest.Migration do
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:name, :text)
      add(:avatar, :text)
      add(:photos, {:array, :string}, null: false, default: [])
      add(:gallery, :map)
    end
  end
end

defmodule Fil.Ecto.RefTest do
  alias Fil.Ecto.RefTest.Migration
  alias Fil.Ecto.RefTest.Photo
  alias Fil.Ecto.RefTest.Repo
  alias Fil.Ecto.RefTest.Storage
  alias Fil.Ecto.RefTest.User

  use ExUnit.Case, async: true

  import Ecto.Changeset
  import Ecto.Query

  setup do
    Fil.Adapter.Memory.checkout()
    {:ok, disk: Storage.uploads()}
  end

  # Each test that needs a database gets its own in-memory SQLite repo, so the tests stay async.
  defp start_repo(_context) do
    pid = start_supervised!({Repo, name: nil, database: ":memory:", pool_size: 1, log: false})
    Repo.put_dynamic_repo(pid)
    :ok = Ecto.Migrator.up(Repo, 1, Migration, log: false)
    :ok
  end

  defp paths(refs), do: Enum.map(refs, &(&1 && &1.path))

  defp with_plugin(disk), do: Fil.attach(disk, :noop, fn op, next, _opts -> next.(op) end)

  describe "init/1" do
    test "takes a capture or an MFA and ignores Ecto's options" do
      capture = &Storage.uploads/0

      assert Fil.Ecto.Ref.init(disk: capture, default: [], field: :photos, schema: User) == %{disk: capture}
      assert Fil.Ecto.Ref.init(disk: {Storage, :uploads, []}) == %{disk: {Storage, :uploads, []}}
    end

    test "refuses an anonymous function, a disk and a missing disk" do
      assert_raise NimbleOptions.ValidationError, ~r/anonymous function/, fn ->
        Fil.Ecto.Ref.init(disk: fn -> Storage.uploads() end)
      end

      disk = Storage.uploads()

      assert_raise NimbleOptions.ValidationError, ~r/got: #Fil.Disk<memory>/, fn ->
        Fil.Ecto.Ref.init(disk: disk)
      end

      assert_raise NimbleOptions.ValidationError, ~r/required :disk option not found/, fn ->
        Fil.Ecto.Ref.init(field: :avatar, schema: User)
      end
    end

    test "raises when the schema compiles" do
      code = """
      defmodule Fil.Ecto.RefTest.Anonymous do
        use Ecto.Schema

        schema "anonymous" do
          field :avatar, Fil.Ecto.Ref, disk: fn -> Fil.Ecto.RefTest.Storage.uploads() end
        end
      end
      """

      assert_raise NimbleOptions.ValidationError, ~r/pass a capture with the module name/, fn ->
        Code.compile_string(code)
      end
    end

    test "gives the schema a parameterized type, in an array too" do
      assert {:parameterized, {Fil.Ecto.Ref, %{disk: _capture}}} = User.__schema__(:type, :avatar)

      assert {:array, {:parameterized, {Fil.Ecto.Ref, %{disk: {Storage, :uploads, []}}}}} =
               User.__schema__(:type, :photos)
    end
  end

  describe "cast" do
    test "takes a ref, normalizes its path and drops its stat", %{disk: disk} do
      avatar = %{Fil.ref(disk, "avatars/1.png") | path: "avatars/./1.png", stat: %Fil.Stat{size: 1}}

      changeset = cast(%User{}, %{"avatar" => avatar}, [:avatar])

      assert changeset.valid?
      assert %Fil.Ref{path: "avatars/1.png", stat: nil, disk: ^disk} = changeset.changes.avatar
    end

    test "takes a ref on the disk with another plugin, which keeps its disk", %{disk: disk} do
      attached = with_plugin(disk)

      changeset = cast(%User{}, %{avatar: Fil.ref(attached, "a.png")}, [:avatar])

      assert changeset.changes.avatar.disk == attached
    end

    test "takes a list of refs in order, and nil in it", %{disk: disk} do
      photos = [Fil.ref(disk, "3.png"), nil, Fil.ref(disk, "1.png")]

      changeset = cast(%User{}, %{"photos" => photos}, [:photos])

      assert changeset.valid?
      assert paths(changeset.changes.photos) == ["3.png", nil, "1.png"]
    end

    test "refuses strings, maps and integers" do
      for value <- ["a.png", %{"path" => "a.png"}, 1] do
        changeset = cast(%User{}, %{"avatar" => value}, [:avatar])

        assert [avatar: {"is invalid", [type: {:parameterized, {Fil.Ecto.Ref, _params}}, validation: :cast]}] =
                 changeset.errors
      end

      changeset = cast(%User{}, %{"photos" => ["a.png"]}, [:photos])
      assert [photos: {"is invalid", _meta}] = changeset.errors
    end

    test "refuses a ref on another disk, with the index in an array", %{disk: disk} do
      elsewhere = Fil.ref(Storage.other(), "a.png")

      single = cast(%User{}, %{"avatar" => elsewhere}, [:avatar])
      assert [avatar: {"is on another disk", _meta}] = single.errors

      array = cast(%User{}, %{"photos" => [Fil.ref(disk, "a.png"), elsewhere]}, [:photos])
      assert [photos: {"is on another disk", meta}] = array.errors
      assert meta[:source] == [1]
    end

    test "refuses a path that leaves the disk root", %{disk: disk} do
      changeset = cast(%User{}, %{"avatar" => Fil.ref(disk, "../a.png")}, [:avatar])

      assert [avatar: {"is not a valid path", _meta}] = changeset.errors
    end

    test "clears the field for nil and an empty string", %{disk: disk} do
      user = %User{avatar: Fil.ref(disk, "a.png")}

      assert cast(user, %{"avatar" => nil}, [:avatar]).changes == %{avatar: nil}
      assert cast(user, %{"avatar" => ""}, [:avatar]).changes == %{avatar: nil}
    end

    test "works in a schemaless changeset", %{disk: disk} do
      types = %{avatar: Ecto.ParameterizedType.init(Fil.Ecto.Ref, disk: &Storage.uploads/0)}

      valid = cast({%{}, types}, %{avatar: Fil.ref(disk, "a.png")}, [:avatar])
      assert valid.changes.avatar.path == "a.png"

      invalid = cast({%{}, types}, %{avatar: "a.png"}, [:avatar])
      assert [avatar: {"is invalid", _meta}] = invalid.errors
    end
  end

  describe "equal?" do
    test "compares paths, so the same path on the disk with another plugin is no change", %{disk: disk} do
      user = %User{avatar: Fil.ref(disk, "a.png"), photos: [Fil.ref(disk, "b.png")]}
      attached = with_plugin(disk)

      params = %{avatar: Fil.ref(attached, "a.png"), photos: [Fil.ref(attached, "b.png")]}
      assert cast(user, params, [:avatar, :photos]).changes == %{}

      put =
        user
        |> change()
        |> put_change(:avatar, Fil.ref(attached, "a.png"))

      assert put.changes == %{}
    end

    test "sees another path or another order as a change", %{disk: disk} do
      user = %User{avatar: Fil.ref(disk, "a.png"), photos: [Fil.ref(disk, "a.png"), Fil.ref(disk, "b.png")]}
      reordered = Enum.reverse(user.photos)

      changeset =
        user
        |> change()
        |> put_change(:avatar, Fil.ref(disk, "b.png"))
        |> put_change(:photos, reordered)

      assert changeset.changes.avatar.path == "b.png"
      assert paths(changeset.changes.photos) == ["b.png", "a.png"]
    end
  end

  describe "dump" do
    setup :start_repo

    test "raises Ecto.ChangeError for a string or a ref on another disk", %{disk: disk} do
      for value <- ["a.png", Fil.ref(Storage.other(), "a.png"), Fil.ref(disk, "../a.png")] do
        changeset =
          %User{}
          |> change()
          |> put_change(:avatar, value)

        error = assert_raise Ecto.ChangeError, fn -> Repo.insert(changeset) end

        assert Exception.message(error) =~ "does not match type Fil.Ecto.Ref"
        refute Exception.message(error) =~ "disk"
      end
    end

    test "raises for an element of an array" do
      changeset =
        %User{}
        |> change()
        |> put_change(:photos, [Fil.ref(Storage.other(), "a.png")])

      assert_raise Ecto.ChangeError, fn -> Repo.insert(changeset) end
    end
  end

  describe "embedded schemas" do
    test "store the path and load a ref", %{disk: disk} do
      photo = %Photo{id: "1", file: Fil.ref(disk, "g.png")}

      assert Ecto.embedded_dump(photo, :json) == %{id: "1", file: "g.png"}
      assert %Photo{file: %Fil.Ref{path: "g.png", disk: ^disk}} = Ecto.embedded_load(Photo, %{"file" => "g.png"}, :json)
    end
  end

  describe "SQLite" do
    setup :start_repo

    test "stores the path and loads a ref on the field's disk", %{disk: disk} do
      attached = with_plugin(disk)
      photos = for name <- ["p/3.png", "p/1.png", "p/2.png"], do: Fil.ref(disk, name)

      {:ok, user} =
        %User{}
        |> cast(%{avatar: Fil.ref(attached, "a.png"), photos: photos}, [:avatar, :photos])
        |> put_embed(:gallery, [%Photo{file: Fil.ref(disk, "g.png")}])
        |> Repo.insert()

      assert user.avatar.disk == attached

      loaded = Repo.get!(User, user.id)
      assert loaded.avatar == Fil.ref(disk, "a.png")
      assert paths(loaded.photos) == ["p/3.png", "p/1.png", "p/2.png"]
      assert [%Photo{file: %Fil.Ref{path: "g.png"}}] = loaded.gallery

      assert %{rows: [["a.png", ~s(["p/3.png","p/1.png","p/2.png"])]]} =
               Repo.query!("SELECT avatar, photos FROM users WHERE id = ?", [user.id])
    end

    test "keeps nil, and defaults to NULL and []", %{disk: disk} do
      {:ok, empty} = Repo.insert(%User{})
      {:ok, holes} = Repo.insert(%User{photos: [Fil.ref(disk, "a.png"), nil]})

      assert %User{avatar: nil, photos: []} = Repo.get!(User, empty.id)
      assert %User{photos: [%Fil.Ref{path: "a.png"}, nil]} = Repo.get!(User, holes.id)
    end

    test "compares with a ref in a query and refuses a string", %{disk: disk} do
      avatar = Fil.ref(disk, "a.png")
      {:ok, user} = Repo.insert(%User{avatar: avatar})

      by_ref = from(u in User, where: u.avatar == ^avatar, select: u.id)
      by_string = from(u in User, where: u.avatar == type(^"a.png", :string), select: u.id)
      avatars = from(u in User, select: u.avatar)

      assert Repo.all(by_ref) == [user.id]
      assert Repo.all(by_string) == [user.id]
      assert Repo.all(avatars) == [avatar]

      untyped = from(u in User, where: u.avatar == ^"a.png")
      assert_raise Ecto.Query.CastError, fn -> Repo.all(untyped) end
    end

    test "insert_all and update_all take refs and refuse strings", %{disk: disk} do
      assert {1, _rows} = Repo.insert_all(User, [%{avatar: Fil.ref(disk, "a.png")}])
      assert {1, _rows} = Repo.update_all(User, set: [avatar: Fil.ref(disk, "b.png")])
      assert [%User{avatar: %Fil.Ref{path: "b.png"}}] = Repo.all(User)

      assert_raise Ecto.ChangeError, fn -> Repo.insert_all(User, [%{avatar: "a.png"}]) end
      assert_raise Ecto.Query.CastError, fn -> Repo.update_all(User, set: [avatar: "a.png"]) end
    end
  end

  describe "removed/2" do
    setup %{disk: disk} do
      {:ok, a: Fil.ref(disk, "a.png"), b: Fil.ref(disk, "b.png"), c: Fil.ref(disk, "c.png")}
    end

    defp stored(fields) do
      User
      |> struct(fields)
      |> Ecto.put_meta(state: :loaded)
    end

    defp removed(user, field, value) do
      user
      |> change()
      |> put_change(field, value)
      |> Fil.Ecto.Ref.removed(field)
    end

    test "returns a replaced or cleared single file", %{a: a, b: b} do
      user = stored(avatar: a)

      assert removed(user, :avatar, b) == [a]
      assert removed(user, :avatar, nil) == [a]
      assert removed(user, :avatar, a) == []
      assert removed(stored([]), :avatar, b) == []
    end

    test "returns the refs an array drops, in their old order", %{a: a, b: b, c: c} do
      user = stored(photos: [a, nil, b, c])

      assert removed(user, :photos, [c, a]) == [b]
      assert removed(user, :photos, [b, c, a]) == []
      assert removed(user, :photos, []) == [a, b, c]
      assert removed(user, :photos, nil) == [a, b, c]
    end

    test "compares paths, not stats or disks", %{a: a, b: b, disk: disk} do
      user = stored(photos: [%{a | stat: %Fil.Stat{size: 1}}, b])
      attached = with_plugin(disk)

      assert removed(user, :photos, [a, Fil.ref(attached, "b.png")]) == []
    end

    test "is empty without a change, and for a record that isn't stored", %{a: a, b: b} do
      assert stored(avatar: a)
             |> change()
             |> Fil.Ecto.Ref.removed(:avatar) == []

      assert removed(%User{avatar: a}, :avatar, b) == []
    end

    test "skips strings in the data of a schemaless changeset", %{a: a} do
      type = Ecto.ParameterizedType.init(Fil.Ecto.Ref, disk: &Storage.uploads/0)
      types = %{photos: {:array, type}}

      changeset = change({%{photos: ["x.png", a]}, types}, photos: [])

      assert Fil.Ecto.Ref.removed(changeset, :photos) == [a]
    end

    test "raises for a field of another type" do
      assert_raise ArgumentError, ~r/expected :name to be a Fil.Ecto.Ref/, fn ->
        removed(stored([]), :name, "x")
      end

      assert_raise ArgumentError, fn -> removed(stored([]), :gallery, []) end
    end
  end
end
