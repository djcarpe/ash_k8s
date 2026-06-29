defmodule AshK8s.Resource.Transformers.InjectBaseSchema do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, dsl_state} <- inject_pk(dsl_state),
         {:ok, dsl_state} <- inject_attributes(dsl_state),
         {:ok, dsl_state} <- inject_actions(dsl_state) do
      {:ok, dsl_state}
    end
  end

  defp inject_pk(dsl_state) do
    if Ash.Resource.Info.attribute(dsl_state, :id) do
      {:ok, dsl_state}
    else
      with {:ok, pk} <-
             Transformer.build_entity(Ash.Resource.Dsl, [:attributes], :uuid_primary_key,
               name: :id
             ) do
        {:ok, Transformer.add_entity(dsl_state, [:attributes], pk)}
      end
    end
  end

  @attributes [
    {:name, :string, [allow_nil?: false, public?: true]},
    {:namespace, :string, [default: "default", public?: true]},
    {:spec, :map, [default: %{}, public?: true]},
    {:status, :map, [default: %{}, public?: true]},
    {:labels, :map, [default: %{}, public?: true]},
    {:annotations, :map, [default: %{}, public?: true]},
    {:resource_version, :string, [public?: true]},
    {:uid, :string, [public?: true]},
    {:generation, :integer, [public?: true]}
  ]

  defp inject_attributes(dsl_state) do
    Enum.reduce_while(@attributes, {:ok, dsl_state}, fn {name, type, opts}, {:ok, state} ->
      case Builder.add_new_attribute(state, name, type, opts) do
        {:ok, new_state} -> {:cont, {:ok, new_state}}
        {:error, e} -> {:halt, {:error, e}}
      end
    end)
  end

  defp inject_actions(dsl_state) do
    with {:ok, dsl_state} <- Builder.add_new_action(dsl_state, :read, :read),
         {:ok, dsl_state} <- Builder.add_new_action(dsl_state, :destroy, :destroy),
         {:ok, dsl_state} <-
           Builder.add_new_action(dsl_state, :create, :create,
             accept: [:name, :namespace, :spec, :labels, :annotations],
             primary?: true
           ),
         {:ok, dsl_state} <-
           Builder.add_new_action(dsl_state, :update, :update,
             accept: [:spec, :labels, :annotations],
             primary?: true
           ),
         {:ok, dsl_state} <-
           Builder.add_new_action(dsl_state, :update, :patch_status, accept: [:status]) do
      {:ok, dsl_state}
    end
  end
end
