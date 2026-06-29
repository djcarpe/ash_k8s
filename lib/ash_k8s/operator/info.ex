defmodule AshK8s.Operator.Info do
  @moduledoc """
  Introspection helpers for Ash domains using the `AshK8s.Operator` extension.
  """

  use Spark.InfoGenerator, extension: AshK8s.Operator, sections: [:operator]

  @doc "Returns the operator name."
  def name!(domain), do: operator_name!(domain)

  @doc "Returns the operator namespace."
  def namespace!(domain), do: operator_namespace!(domain)

  @doc "Returns true if leader election is enabled."
  def leader_election?(domain) do
    Spark.Dsl.Extension.get_opt(domain, [:operator], :leader_election?, false)
  end

  @doc "Returns the list of `AshK8s.Operator.Entities.Watch` structs."
  def watches!(domain) do
    Spark.Dsl.Extension.get_entities(domain, [:operator, :watches])
  end

  @doc "Returns the Watch entry for a given resource module, or nil."
  def watch_for_resource(domain, resource) do
    domain |> watches!() |> Enum.find(&(&1.resource == resource))
  end
end
