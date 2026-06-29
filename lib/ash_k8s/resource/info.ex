defmodule AshK8s.Resource.Info do
  @moduledoc """
  Introspection helpers for Ash resources that use the `AshK8s.Resource` extension.
  """

  use Spark.InfoGenerator, extension: AshK8s.Resource, sections: [:k8s]

  @doc "Returns the API group (e.g. `\"apps.example.com\"`)."
  def group!(resource), do: k8s_group!(resource)

  @doc "Returns the API version (e.g. `\"v1\"`)."
  def version!(resource), do: k8s_version!(resource)

  @doc "Returns the resource scope (`:namespaced` or `:cluster`)."
  def scope!(resource), do: k8s_scope!(resource)

  @doc "Returns the plural resource name."
  def plural!(resource), do: k8s_plural!(resource)

  @doc "Returns the singular resource name."
  def singular!(resource), do: k8s_singular!(resource)

  @doc "Returns the CRD Kind string."
  def kind!(resource), do: k8s_kind!(resource)

  @doc "Returns the list of short names."
  def short_names!(resource), do: k8s_short_names!(resource)

  @doc "Returns the categories list."
  def categories!(resource), do: k8s_categories!(resource)

  @doc "Returns the printer column entities."
  def printer_columns!(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:k8s, :printer_columns])
  end

  @doc "Returns the status condition entities."
  def status_conditions!(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:k8s, :status])
  end

  @doc "Returns true if the status subresource is enabled."
  def status_enabled?(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:k8s, :status], :enabled, true)
  end

  @doc """
  Returns the full API version string.

  For custom/extension groups: `\"apps.example.com/v1\"`.
  For the core API group (empty group): `\"v1\"`.
  """
  def api_version!(resource) do
    case group!(resource) do
      "" -> version!(resource)
      group -> "#{group}/#{version!(resource)}"
    end
  end

  @doc "Returns the base URL path for this resource (without namespace)."
  def api_path!(resource) do
    case group!(resource) do
      "" -> "/api/#{version!(resource)}/#{plural!(resource)}"
      group -> "/apis/#{group}/#{version!(resource)}/#{plural!(resource)}"
    end
  end

  @doc "Returns the namespaced URL path for this resource."
  def namespaced_api_path!(resource, namespace) do
    case group!(resource) do
      "" -> "/api/#{version!(resource)}/namespaces/#{namespace}/#{plural!(resource)}"
      group -> "/apis/#{group}/#{version!(resource)}/namespaces/#{namespace}/#{plural!(resource)}"
    end
  end
end
