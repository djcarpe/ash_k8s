defmodule AshK8s.CRD do
  @moduledoc """
  Generates Kubernetes CRD manifests from Ash resource definitions.

  ## Usage

      # Generate a CRD map
      crd = AshK8s.CRD.generate(MyApp.Widgets.Widget)

      # Serialize to YAML
      yaml = AshK8s.CRD.to_yaml(crd)

      # Write to file
      File.write!("crds/widgets.yaml", yaml)

      # Generate and write all CRDs for a domain
      AshK8s.CRD.generate_all(MyApp.Widgets)
      |> Enum.each(fn {resource, yaml} ->
        File.write!("crds/\#{resource}.yaml", yaml)
      end)

  ## Mix task

  You can also run `mix ash_k8s.gen.crds` to generate CRD files.
  """

  alias AshK8s.Resource.Info

  @doc "Generates a CRD manifest map for the given Ash resource module."
  @spec generate(module()) :: map()
  def generate(resource) do
    group = Info.group!(resource)
    version = Info.version!(resource)
    kind = Info.kind!(resource)
    plural = Info.plural!(resource)
    singular = Info.singular!(resource)
    scope = Info.scope!(resource) |> Atom.to_string() |> String.capitalize()
    short_names = Info.short_names!(resource)
    categories = Info.categories!(resource)
    printer_columns = Info.printer_columns!(resource)
    status_enabled = Info.status_enabled?(resource)
    attributes = Ash.Resource.Info.attributes(resource)

    schema = build_schema(attributes)

    version_entry =
      %{
        "name" => version,
        "served" => true,
        "storage" => Spark.Dsl.Extension.get_opt(resource, [:k8s], :storage, true),
        "schema" => %{
          "openAPIV3Schema" => schema
        }
      }
      |> maybe_put_status_subresource(status_enabled)
      |> maybe_put_printer_columns(printer_columns)

    crd = %{
      "apiVersion" => "apiextensions.k8s.io/v1",
      "kind" => "CustomResourceDefinition",
      "metadata" => %{
        "name" => "#{plural}.#{group}"
      },
      "spec" => %{
        "group" => group,
        "names" => build_names(kind, plural, singular, short_names, categories),
        "scope" => scope,
        "versions" => [version_entry]
      }
    }

    crd
  end

  @doc "Generates CRDs for all AshK8s-enabled resources in a domain."
  @spec generate_all(module()) :: [{module(), map()}]
  def generate_all(domain) do
    domain
    |> Ash.Domain.Info.resources()
    |> Enum.filter(&uses_ash_k8s?/1)
    |> Enum.map(&{&1, generate(&1)})
  end

  @doc "Serializes a CRD map to YAML."
  @spec to_yaml(map()) :: String.t()
  def to_yaml(crd) do
    Ymlr.document!(crd)
  end

  @doc "Generates YAML for a single resource."
  @spec generate_yaml(module()) :: String.t()
  def generate_yaml(resource) do
    resource |> generate() |> to_yaml()
  end

  # ---- Private ----

  defp build_names(kind, plural, singular, short_names, categories) do
    base = %{
      "kind" => kind,
      "listKind" => kind <> "List",
      "plural" => plural,
      "singular" => singular
    }

    base =
      if short_names != [],
        do: Map.put(base, "shortNames", short_names),
        else: base

    if categories != [],
      do: Map.put(base, "categories", categories),
      else: base
  end

  defp build_schema(attributes) do
    properties =
      attributes
      |> Enum.reject(&(&1.name in [:id, :resource_version, :uid, :generation]))
      |> Enum.map(fn attr ->
        {to_string(attr.name), ash_type_to_openapi(attr.type, attr)}
      end)
      |> Map.new()

    # apiVersion, kind, and metadata are always implicit in CRDs — including them
    # in openAPIV3Schema causes validation errors in K8s 1.25+.
    %{
      "type" => "object",
      "properties" => %{
        "spec" => properties_for_spec(properties),
        "status" => %{"type" => "object", "x-kubernetes-preserve-unknown-fields" => true}
      }
    }
  end

  defp properties_for_spec(all_properties) do
    # Remove top-level metadata attributes from spec since they live in metadata.
    metadata_keys = ~w(name namespace labels annotations status spec)

    spec_props =
      all_properties
      |> Map.drop(metadata_keys)

    if map_size(spec_props) > 0 do
      %{
        "type" => "object",
        "properties" => spec_props,
        "x-kubernetes-preserve-unknown-fields" => true
      }
    else
      %{"type" => "object", "x-kubernetes-preserve-unknown-fields" => true}
    end
  end

  defp ash_type_to_openapi(Ash.Type.String, attr), do: string_schema(attr)
  defp ash_type_to_openapi(:string, attr), do: string_schema(attr)
  defp ash_type_to_openapi(Ash.Type.Integer, _attr), do: %{"type" => "integer"}
  defp ash_type_to_openapi(:integer, _attr), do: %{"type" => "integer"}
  defp ash_type_to_openapi(Ash.Type.Float, _attr), do: %{"type" => "number"}
  defp ash_type_to_openapi(:float, _attr), do: %{"type" => "number"}
  defp ash_type_to_openapi(Ash.Type.Decimal, _attr), do: %{"type" => "number"}
  defp ash_type_to_openapi(Ash.Type.Boolean, _attr), do: %{"type" => "boolean"}
  defp ash_type_to_openapi(:boolean, _attr), do: %{"type" => "boolean"}

  defp ash_type_to_openapi(Ash.Type.Map, _attr),
    do: %{"type" => "object", "x-kubernetes-preserve-unknown-fields" => true}

  defp ash_type_to_openapi(:map, _attr),
    do: %{"type" => "object", "x-kubernetes-preserve-unknown-fields" => true}

  defp ash_type_to_openapi({:array, inner_type}, attr) do
    %{"type" => "array", "items" => ash_type_to_openapi(inner_type, attr)}
  end

  defp ash_type_to_openapi(Ash.Type.UUID, _attr), do: %{"type" => "string", "format" => "uuid"}

  defp ash_type_to_openapi(Ash.Type.DateTime, _attr),
    do: %{"type" => "string", "format" => "date-time"}

  defp ash_type_to_openapi(Ash.Type.Date, _attr), do: %{"type" => "string", "format" => "date"}
  defp ash_type_to_openapi(Ash.Type.Atom, _attr), do: %{"type" => "string"}
  defp ash_type_to_openapi(:atom, _attr), do: %{"type" => "string"}
  defp ash_type_to_openapi(_unknown, _attr), do: %{"x-kubernetes-preserve-unknown-fields" => true}

  defp string_schema(_attr), do: %{"type" => "string"}

  defp maybe_put_status_subresource(version_entry, true) do
    Map.put(version_entry, "subresources", %{"status" => %{}})
  end

  defp maybe_put_status_subresource(version_entry, _), do: version_entry

  defp maybe_put_printer_columns(version_entry, []), do: version_entry

  defp maybe_put_printer_columns(version_entry, columns) do
    printer_columns =
      Enum.map(columns, fn col ->
        base = %{
          "name" => col.name,
          "type" => col.type,
          "jsonPath" => col.json_path
        }

        base
        |> maybe_add("description", col.description)
        |> maybe_add("format", col.format)
        |> Map.put("priority", col.priority || 0)
      end)

    Map.put(version_entry, "additionalPrinterColumns", printer_columns)
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp uses_ash_k8s?(resource) do
    AshK8s.Resource in Spark.extensions(resource)
  rescue
    _ -> false
  end
end
