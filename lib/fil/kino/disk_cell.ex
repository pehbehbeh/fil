if Code.ensure_loaded?(Kino.JS.Live) do
  defmodule Fil.Kino.DiskCell do
    @moduledoc false

    # The "Fil disk" smart cell: a form that generates the `Fil.disk/1` call for a Local, S3 or Memory disk.
    # `Fil.Application` registers it when Kino is there. Secrets are names of Livebook secrets, without the `LB_` prefix
    # Livebook puts in front of them in the environment.

    use Kino.JS, assets_path: "lib/fil/kino/assets", entrypoint: "disk_cell.js"
    use Kino.JS.Live
    use Kino.SmartCell, name: "Fil disk"

    @adapters %{"local" => Fil.Adapter.Local, "s3" => Fil.Adapter.S3, "memory" => Fil.Adapter.Memory}

    @s3_fields ~w(bucket region endpoint path_style access_key_id_secret secret_access_key_secret)

    # The options the text fields become, in the order of the generated code.
    @s3_options ~w(bucket region root endpoint)a

    @impl Kino.JS.Live
    def init(attrs, ctx) do
      fields = %{
        "variable" => variable(attrs["variable"]),
        "adapter" => if(Map.has_key?(@adapters, attrs["adapter"]), do: attrs["adapter"], else: "local"),
        "root" => attrs["root"] || "",
        "bucket" => attrs["bucket"] || "",
        "region" => attrs["region"] || "",
        "endpoint" => attrs["endpoint"] || "",
        "path_style" => attrs["path_style"] == true,
        "access_key_id_secret" => attrs["access_key_id_secret"] || "",
        "secret_access_key_secret" => attrs["secret_access_key_secret"] || ""
      }

      {:ok, assign(ctx, fields: fields)}
    end

    # `prefixed_var_name/2` marks the name as taken, so the next cell defaults to `disk2`.
    defp variable(name) do
      name = if is_binary(name) and Kino.SmartCell.valid_variable_name?(name), do: name
      Kino.SmartCell.prefixed_var_name("disk", name)
    end

    @impl Kino.JS.Live
    def handle_connect(ctx), do: {:ok, %{fields: ctx.assigns.fields}, ctx}

    @impl Kino.JS.Live
    def handle_event("update_field", %{"field" => field, "value" => value}, ctx) do
      fields = ctx.assigns.fields
      value = field_value(field, value, fields)

      if Map.has_key?(fields, field) and value != nil do
        # The client that sent it needs the update too, when an invalid variable name was replaced.
        broadcast_event(ctx, "update", %{"fields" => %{field => value}})
        {:noreply, assign(ctx, fields: Map.put(fields, field, value))}
      else
        {:noreply, ctx}
      end
    end

    def handle_event(_event, _payload, ctx), do: {:noreply, ctx}

    defp field_value("variable", value, fields) when is_binary(value) do
      if Kino.SmartCell.valid_variable_name?(value), do: value, else: fields["variable"]
    end

    defp field_value("adapter", value, _fields), do: if(Map.has_key?(@adapters, value), do: value)
    defp field_value("path_style", value, _fields) when is_boolean(value), do: value
    defp field_value("path_style", _value, _fields), do: nil
    defp field_value(_field, value, _fields) when is_binary(value), do: String.trim(value)
    defp field_value(_field, _value, _fields), do: nil

    @impl Kino.SmartCell
    def to_attrs(ctx) do
      fields = ctx.assigns.fields

      keys =
        if fields["adapter"] == "s3", do: ["variable", "adapter", "root" | @s3_fields], else: ~w(variable adapter root)

      Map.take(fields, keys)
    end

    @impl Kino.SmartCell
    def to_source(attrs) do
      # The name passed `valid_variable_name?/1`, which makes the same atom, and a variable in code needs one.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      name = String.to_atom(attrs["variable"])
      variable = Macro.var(name, nil)
      options = [{:adapter, Map.fetch!(@adapters, attrs["adapter"])} | options(attrs)]
      disk = quote do: unquote(variable) = Fil.disk(unquote(options))

      # A memory disk needs a store, and the evaluator of the notebook owns it.
      quoted =
        if attrs["adapter"] == "memory" do
          {:__block__, [], [quote(do: Fil.Adapter.Memory.checkout()), disk]}
        else
          disk
        end

      Kino.SmartCell.quoted_to_string(quoted)
    end

    # Empty fields are left out, so the adapter's defaults apply.
    defp options(%{"adapter" => "s3"} = attrs) do
      Enum.concat([
        strings(attrs, @s3_options),
        if(attrs["path_style"], do: [path_style: true], else: []),
        secret(:access_key_id, attrs["access_key_id_secret"]),
        secret(:secret_access_key, attrs["secret_access_key_secret"])
      ])
    end

    defp options(attrs), do: strings(attrs, [:root])

    defp strings(attrs, options) do
      for option <- options, value = attrs[Atom.to_string(option)], present?(value), do: {option, value}
    end

    defp secret(option, name) do
      if present?(name), do: [{option, quote(do: System.fetch_env!(unquote("LB_" <> name)))}], else: []
    end

    defp present?(value), do: is_binary(value) and value != ""
  end
end
