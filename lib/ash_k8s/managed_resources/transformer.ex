defmodule AshK8s.ManagedResources.Transformer do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias AshK8s.ManagedResources.Catalog

  def before?(Ash.Domain.Transformers.DedupResources), do: true
  def before?(_), do: false
  def after?(_), do: false

  def transform(dsl_state) do
    domain_module = Transformer.get_persisted(dsl_state, :module)
    entities = Transformer.get_entities(dsl_state, [:managed_resources])

    Enum.reduce_while(entities, {:ok, dsl_state}, fn entity, {:ok, state} ->
      entry = Catalog.fetch!(entity.kind)
      resource_module = entity.module || Module.concat(domain_module, entry.kind)

      with :ok <- ensure_resource_module(resource_module, domain_module, entry, entity),
           {:ok, state} <- register_in_domain(state, resource_module),
           {:ok, state} <- maybe_add_watch(state, resource_module, entity.controller) do
        {:cont, {:ok, state}}
      else
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  # --------------------------------------------------------------------------
  # Module generation
  # --------------------------------------------------------------------------

  defp ensure_resource_module(resource_module, domain_module, entry, entity) do
    if Code.ensure_loaded?(resource_module) do
      :ok
    else
      body = build_resource_ast(domain_module, entry, entity.printer_columns)
      Module.create(resource_module, body, __ENV__)
      :ok
    end
  end

  defp build_resource_ast(domain_module, entry, printer_columns) do
    columns_ast = columns_block(printer_columns)

    quote do
      use Ash.Resource,
        domain: unquote(domain_module),
        extensions: [AshK8s.Resource],
        data_layer: AshK8s.DataLayer

      k8s do
        group(unquote(entry.group))
        version(unquote(entry.version))
        plural(unquote(entry.plural))
        singular(unquote(entry.singular))
        kind unquote(entry.kind)
        scope(unquote(entry.scope))

        unquote(columns_ast)
      end
    end
  end

  defp columns_block([]), do: nil

  defp columns_block(columns) do
    column_exprs =
      Enum.map(columns, fn col ->
        opts =
          [json_path: col.json_path, type: col.type, priority: col.priority]
          |> put_if(:format, col.format)
          |> put_if(:description, col.description)

        quote do
          column(unquote(col.name), unquote(opts))
        end
      end)

    quote do
      printer_columns do
        (unquote_splicing(column_exprs))
      end
    end
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  # --------------------------------------------------------------------------
  # Domain resource registration
  # --------------------------------------------------------------------------

  defp register_in_domain(dsl_state, resource_module) do
    with {:ok, entity} <-
           Transformer.build_entity(Ash.Domain.Dsl, [:resources], :resource,
             resource: resource_module
           ) do
      {:ok, Transformer.add_entity(dsl_state, [:resources], entity)}
    end
  end

  # --------------------------------------------------------------------------
  # Operator watch registration (only when AshK8s.Operator is also active)
  # --------------------------------------------------------------------------

  defp maybe_add_watch(dsl_state, _resource_module, nil), do: {:ok, dsl_state}

  defp maybe_add_watch(dsl_state, resource_module, controller) do
    extensions = Transformer.get_persisted(dsl_state, :spark_extensions) || []

    if AshK8s.Operator in extensions do
      with {:ok, entity} <-
             Transformer.build_entity(AshK8s.Operator, [:operator, :watches], :watch,
               resource: resource_module,
               controller: controller
             ) do
        {:ok, Transformer.add_entity(dsl_state, [:operator, :watches], entity)}
      end
    else
      {:ok, dsl_state}
    end
  end
end
