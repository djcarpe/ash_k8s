defmodule AshK8s.Resource.Transformers.SetDefaults do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    base_name = module |> Module.split() |> List.last()

    singular =
      Transformer.get_option(dsl_state, [:k8s], :singular) ||
        Macro.underscore(base_name)

    plural =
      Transformer.get_option(dsl_state, [:k8s], :plural) ||
        singular <> "s"

    kind =
      Transformer.get_option(dsl_state, [:k8s], :kind) ||
        base_name

    dsl_state =
      dsl_state
      |> Transformer.set_option([:k8s], :singular, singular)
      |> Transformer.set_option([:k8s], :plural, plural)
      |> Transformer.set_option([:k8s], :kind, kind)

    {:ok, dsl_state}
  end
end
