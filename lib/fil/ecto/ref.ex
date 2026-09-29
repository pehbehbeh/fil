if Code.ensure_loaded?(Ecto.ParameterizedType) do
  defmodule Fil.Ecto.Ref do
    @schema NimbleOptions.new!(
              disk: [
                type: Fil.Support.DiskOption.type([:remote_fun, :mfa]),
                required: true,
                doc: """
                #{Fil.Support.DiskOption.doc([:remote_fun, :mfa])} Ecto compiles field options into the schema module,
                so an anonymous function or a disk raises at compile time, and the arguments of an MFA end up in the
                compiled code: `{MyApp.Storage, :disk, [:uploads]}` is fine, credentials in the arguments are not. The
                function has to return a disk on the same storage each time (see [Same storage](#module-same-storage)).
                """
              ]
            )

    @moduledoc """
    An [Ecto](https://hexdocs.pm/ecto) type for files on a disk. The column holds the path, and loading a record returns
    a `Fil.Ref` on the disk the field names:

        schema "users" do
          field :avatar, Fil.Ecto.Ref, disk: &MyApp.Storage.uploads/0
          field :photos, {:array, Fil.Ecto.Ref}, disk: &MyApp.Storage.uploads/0, default: []
        end

    The refs that `Fil.LiveView.consume_uploaded_entries/4` returns go into the changeset with
    `Ecto.Changeset.put_change/3`:

        {:ok, [avatar]} = Fil.LiveView.consume_uploaded_entries(socket, :avatar, &MyApp.Storage.uploads/0)

        user
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_change(:avatar, avatar)
        |> Repo.update()

    Only the path is stored, never the disk: a disk may hold credentials, and it's built from the config of the
    environment the app runs in. The field's disk is resolved with `Fil.Disk.resolve/1` each time a value is cast,
    loaded or dumped, so a function can build it from runtime config.

    Use a `:text` column for a single file (S3 keys can be 1,024 bytes long, `:string` is `varchar(255)` on Postgres
    and MySQL):

        add :avatar, :text

    Needs Ecto 3.12, an optional dependency of `Fil`. The type does no I/O: it never checks that a file exists, and it
    never deletes one (see [Deleting replaced files](#module-deleting-replaced-files)).

    ## Several files

    `{:array, Fil.Ecto.Ref}` holds several files in order. The column depends on the database:

        # Postgres: a text[] column
        add :photos, {:array, :text}, null: false, default: []

        # SQLite (ecto_sqlite3): JSON in a TEXT column
        add :photos, {:array, :string}, null: false, default: []

        # MySQL: a JSON column (the default needs MySQL 8.0.13)
        add :photos, :json, null: false, default: fragment("(JSON_ARRAY())")

    A NULL column loads as `nil`, not `[]`, hence `null: false` with a default. A `nil` in the list is kept, as with
    `{:array, Ecto.Enum}`: `[photo, nil]` is stored and loaded as it is.

    ## Casting

    The field takes a `Fil.Ref` or `nil`, through `Ecto.Changeset.cast/4` and `Ecto.Changeset.put_change/3` alike.
    Casting normalizes the path and drops `:stat`. A ref on another disk gives the changeset error "is on another
    disk", and a path that leaves the disk root "is not a valid path".

    Strings give "is invalid", because a string could come from a form, and a form could point the record at any file
    on the disk. So leave the field out of `cast/4` for user params, and put the refs you stored with `put_change/3`.
    An empty string in the params would clear the field, too: `cast/4` turns empty values into the default before the
    type sees them.

    `put_change/3` doesn't cast, so dumping the value checks it again: a string or a ref on another disk in a
    `put_change/3` raises `Ecto.ChangeError` at the insert or update, instead of storing a path that means another
    file. `c:Ecto.Repo.insert_all/3` and `c:Ecto.Repo.update_all/3` take refs too. `insert_all/3` raises
    `Ecto.ChangeError` for a string, and `update_all/3` raises `Ecto.Query.CastError`, because its values are query
    parameters.

    A schemaless changeset gets the type from `Ecto.ParameterizedType.init/2`:

        types = %{avatar: Ecto.ParameterizedType.init(Fil.Ecto.Ref, disk: &MyApp.Storage.uploads/0)}
        changeset = Ecto.Changeset.cast({%{}, types}, %{avatar: avatar}, [:avatar])

    Two refs are equal when their paths are. Putting back the ref a record loaded, or one to the same path on the disk
    with other plugins, is no change.

    ## Same storage

    A ref fits the field when its disk is the same storage as the field's disk, as `Fil.Disk.same_storage?/2` decides:
    the same adapter and the same address, such as the same root, or the same bucket and prefix. Plugins, credentials
    and other options that only change how the storage is reached don't count. So a ref from the disk with another
    plugin attached fits, and so does one from a disk built before the S3 credentials were rotated. A ref on a local
    disk with another root doesn't.

    ## Loading

    Each loaded value calls the disk function, once per ref (Ecto loads array elements one by one). A function that
    builds an S3 disk with `Fil.disk/1` validates its options each time, which adds about 10 µs per ref. For large
    result sets, build the disk once at boot and return it:

        # in MyApp.Application.start/2
        :persistent_term.put({MyApp.Storage, :uploads}, Fil.disk(uploads_options))

        # in MyApp.Storage
        def uploads, do: :persistent_term.get({__MODULE__, :uploads})

    Loading builds the ref with `Fil.ref/2`, which normalizes the path and keeps one it can't normalize, such as
    `"../x.png"`, unchanged. An operation on that ref returns a `Fil.InvalidRequestError`. An empty string loads as the
    disk root, `"."`.

    After `c:Ecto.Repo.insert/2`, the struct holds the refs that were cast or put, with their own disks, and a reload
    gives refs on the field's disk. Both name the same files.

    ## Queries

    A value compared with the field is cast and dumped with its type, so it has to be a ref:

        from u in User, where: u.avatar == ^Fil.ref(MyApp.Storage.uploads(), "avatars/1.png")

    `where: u.avatar == ^"avatars/1.png"` raises `Ecto.Query.CastError`. `type(^path, :string)` compares with a string
    on Postgres and SQLite, but MySQL may refuse it with "Illegal mix of collations". `select: u.avatar` loads refs.

    ## Deleting replaced files

    The type can't delete anything, because it doesn't know whether the transaction commits. `removed/2` returns the
    refs a changeset drops, so you delete them after the commit:

        changeset =
          product
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.put_change(:photos, kept_photos ++ new_photos)

        removed = Fil.Ecto.Ref.removed(changeset, :photos)

        with {:ok, product} <- Repo.update(changeset) do
          Enum.each(removed, &Fil.rm/1)
          {:ok, product}
        end

    `removed/2` compares with `changeset.data`, the record as it was loaded, so when two requests edit the same record
    at once, one can delete a file that the other saves again, unless you use `Ecto.Changeset.optimistic_lock/3` or load
    the record with a row lock in the transaction.

    Clearing a single file works the same way, with `put_change(:avatar, nil)`. Inside a transaction, delete after the
    outermost one. If a delete fails, the file stays on the disk without a record, which is better than a record without
    its file.

    Deleting a record leaves its files: delete them after `c:Ecto.Repo.delete/2`, with
    `Enum.each(List.wrap(product.photos), &Fil.rm/1)`. When the changeset is invalid after a consume, the files the
    consume stored belong to no record, so delete those refs.

    ## Embedded schemas

    A field in an embedded schema stores the path as well, so the JSON of an embed holds paths, not disks.

    ## Rendering and JSON

    `Fil.Ref` implements neither `Phoenix.HTML.Safe` nor `Jason.Encoder`, so `{@user.avatar}` in HEEx and
    `Jason.encode!(user.avatar)` raise. A page needs a URL anyway, from `Fil.url/2` or `Fil.signed_url/3`:

        {:ok, avatar_url} = Fil.signed_url(user.avatar, expires_in: 3600)

    ## Options

    #{NimbleOptions.docs(@schema)}
    """

    use Ecto.ParameterizedType

    @impl Ecto.ParameterizedType
    def init(opts) do
      # Ecto passes every field option, plus `:field` and `:schema`, and leaves the check to the type. The others
      # (`:default`, `:load_in_query` and so on) are Ecto's.
      opts
      |> Keyword.take([:disk])
      |> NimbleOptions.validate!(@schema)
      |> Map.new()
    end

    @impl Ecto.ParameterizedType
    def type(_params), do: :string

    @impl Ecto.ParameterizedType
    def cast(nil, _params), do: {:ok, nil}

    def cast(%Fil.Ref{disk: %Fil.Disk{}, path: path} = ref, params) when is_binary(path) do
      case check(ref, params) do
        {:ok, ref} -> {:ok, ref}
        {:error, :disk} -> {:error, message: "is on another disk"}
        {:error, :path} -> {:error, message: "is not a valid path"}
      end
    end

    def cast(_other, _params), do: :error

    @impl Ecto.ParameterizedType
    def load(nil, _loader, _params), do: {:ok, nil}

    def load(path, _loader, %{disk: source}) when is_binary(path) do
      ref =
        source
        |> Fil.Disk.resolve()
        |> Fil.ref(path)

      {:ok, ref}
    end

    def load(_other, _loader, _params), do: :error

    @impl Ecto.ParameterizedType
    def dump(nil, _dumper, _params), do: {:ok, nil}

    def dump(%Fil.Ref{disk: %Fil.Disk{}, path: path} = ref, _dumper, params) when is_binary(path) do
      case check(ref, params) do
        {:ok, ref} -> {:ok, ref.path}
        {:error, _reason} -> :error
      end
    end

    def dump(_other, _dumper, _params), do: :error

    @impl Ecto.ParameterizedType
    def equal?(%Fil.Ref{path: path}, %Fil.Ref{path: path}, _params), do: true
    def equal?(term1, term2, _params), do: term1 == term2

    # `:dump` stores the path in embeds. The default, `:self`, would put the whole ref into the JSON, disk included.
    @impl Ecto.ParameterizedType
    def embed_as(_format, _params), do: :dump

    # Without it, errors print the params, `#Fil.Ecto.Ref<%{disk: ...}>`.
    @impl Ecto.ParameterizedType
    def format(_params), do: "Fil.Ecto.Ref"

    # Cast and dump check the same, because `put_change/3` doesn't cast.
    defp check(ref, %{disk: source}) do
      disk = Fil.Disk.resolve(source)

      if Fil.Disk.same_storage?(ref.disk, disk), do: normalize(ref), else: {:error, :disk}
    end

    defp normalize(ref) do
      case Fil.Ref.normalize(ref) do
        {:ok, ref} -> {:ok, ref}
        {:error, %Fil.InvalidRequestError{}} -> {:error, :path}
      end
    end

    @doc """
    Returns the refs that `changeset` drops from `field`, a `Fil.Ecto.Ref` or `{:array, Fil.Ecto.Ref}` field.

    These are the refs in the changeset's data whose path isn't among the paths of the change, in their order, each
    path once. Without a change the list is empty. Nothing is deleted; delete the refs after the commit (see
    [Deleting replaced files](#module-deleting-replaced-files)).

        iex> disk = Fil.disk(adapter: Fil.Adapter.Memory)
        iex> type = Ecto.ParameterizedType.init(Fil.Ecto.Ref, disk: {Fil, :disk, [[adapter: Fil.Adapter.Memory]]})
        iex> data = %{avatar: Fil.ref(disk, "avatars/old.png")}
        iex> changeset = Ecto.Changeset.change({data, %{avatar: type}}, avatar: Fil.ref(disk, "avatars/new.png"))
        iex> changeset
        ...> |> Fil.Ecto.Ref.removed(:avatar)
        ...> |> Enum.map(& &1.path)
        ["avatars/old.png"]

    It compares paths, not whole refs, so a kept ref with a `:stat` or on the disk with other plugins isn't removed.
    `nil` in an array field is skipped, and so are strings in the data (a schemaless changeset may hold paths). An
    array field changed to `nil` drops all its refs. Raises `ArgumentError` when `field` isn't one of the two types.

    It compares with the changeset's data, whatever the record's state. For a changeset on a copy of another record,
    such as `%{product | id: nil}`, the refs it returns still belong to that record, so don't delete them.
    """
    @spec removed(Ecto.Changeset.t(), atom()) :: [Fil.Ref.t()]
    def removed(%Ecto.Changeset{} = changeset, field) when is_atom(field) do
      check_type!(changeset, field)

      case Ecto.Changeset.fetch_change(changeset, field) do
        {:ok, new} -> dropped(changeset.data, field, new)
        :error -> []
      end
    end

    defp check_type!(changeset, field) do
      case Map.fetch(changeset.types, field) do
        {:ok, {:parameterized, {__MODULE__, _params}}} ->
          :ok

        {:ok, {:array, {:parameterized, {__MODULE__, _params}}}} ->
          :ok

        _other ->
          raise ArgumentError, "expected #{inspect(field)} to be a Fil.Ecto.Ref or {:array, Fil.Ecto.Ref} field"
      end
    end

    defp dropped(data, field, new) do
      kept =
        new
        |> refs()
        |> MapSet.new(& &1.path)

      data
      |> Map.get(field)
      |> refs()
      |> Enum.reject(&MapSet.member?(kept, &1.path))
      |> Enum.uniq_by(& &1.path)
    end

    defp refs(value) do
      value
      |> List.wrap()
      |> Enum.filter(&match?(%Fil.Ref{}, &1))
    end
  end
end
