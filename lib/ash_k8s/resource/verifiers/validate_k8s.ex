defmodule AshK8s.Resource.Verifiers.ValidateK8s do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    group = Verifier.get_option(dsl_state, [:k8s], :group)

    cond do
      is_nil(group) ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:k8s, :group],
           message: "k8s group is required (use \"\" for the core API group)"
         )}

      # Empty string = core K8s API group (/api/v1/...) — always valid.
      group == "" ->
        :ok

      not valid_dns_subdomain?(group) ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:k8s, :group],
           message: "k8s group must be a valid DNS subdomain (e.g. \"apps.example.com\")"
         )}

      true ->
        :ok
    end
  end

  defp valid_dns_subdomain?(str) do
    String.match?(str, ~r/^[a-z0-9]([a-z0-9\-\.]*[a-z0-9])?$/)
  end
end
