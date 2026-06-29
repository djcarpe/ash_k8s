defmodule AshK8s.Operator.Verifiers.ValidateWatches do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    watches = Verifier.get_entities(dsl_state, [:operator, :watches])

    errors =
      Enum.flat_map(watches, fn watch ->
        cond do
          not ash_k8s_resource?(watch.resource) ->
            [
              "Watch target #{inspect(watch.resource)} must use the AshK8s.Resource extension"
            ]

          not implements_controller?(watch.controller) ->
            [
              "Controller #{inspect(watch.controller)} must implement AshK8s.Controller.Behaviour"
            ]

          true ->
            []
        end
      end)

    case errors do
      [] ->
        :ok

      [_ | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:operator, :watches],
           message: Enum.join(errors, "\n")
         )}
    end
  end

  defp ash_k8s_resource?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :spark_dsl_config, 0) and
      AshK8s.Resource in Spark.extensions(module)
  rescue
    _ -> false
  end

  defp implements_controller?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :reconcile, 3)
  end
end
