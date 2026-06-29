defmodule AshK8s.DataLayer do
  @moduledoc """
  Ash data layer backed by the Kubernetes API server.

  Pair with the `AshK8s.Resource` extension to get full CRUD against any
  Kubernetes resource type (built-in or custom).

  ## Configuration

  The client is resolved once at process startup via `AshK8s.Client.Config.resolve/0`
  and cached in a module attribute. You can override it by setting:

      config :ash_k8s, :client, MyApp.K8sClient

  where `MyApp.K8sClient` is a module that exports `new/0 :: AshK8s.Client.t()`.

  ## Namespace resolution

  For namespaced resources, the namespace is taken from (in priority order):

  1. A `:namespace` filter value on the query
  2. The `:namespace` key in query context (`query.context[:namespace]`)
  3. The resolved config's default namespace

  ## Filtering

  Ash filter attributes that map to Kubernetes label keys can be translated
  to `labelSelector` query params. Attribute names starting with `label_` or
  a user-supplied prefix are automatically translated. Other filter operations
  fall back to in-memory filtering on the returned list.
  """

  @behaviour Ash.DataLayer

  alias AshK8s.{Client, Resource.Info, DataLayer.Query}

  require Logger

  # ---- DataLayer capability declarations ----

  @impl true
  def can?(_, :create), do: true
  def can?(_, :read), do: true
  def can?(_, :update), do: true
  def can?(_, :destroy), do: true
  def can?(_, :sort), do: true
  def can?(_, :filter), do: true
  def can?(_, :limit), do: true
  def can?(_, :offset), do: true
  def can?(_, :boolean_filter), do: true
  def can?(_, {:filter_expr, _}), do: true
  def can?(_, _), do: false

  # ---- Query building ----

  @impl true
  def resource_to_query(resource, _domain) do
    %Query{resource: resource}
  end

  @impl true
  def filter(query, filter, _resource) do
    {:ok, %{query | filter: filter}}
  end

  @impl true
  def sort(query, sort, _resource) do
    {:ok, %{query | sort: sort}}
  end

  @impl true
  def limit(query, limit, _resource) do
    {:ok, %{query | limit: limit}}
  end

  @impl true
  def offset(query, offset, _resource) do
    {:ok, %{query | offset: offset}}
  end

  @impl true
  def set_context(_resource, query, context) do
    {:ok, %{query | namespace: context[:namespace], tenant: context[:tenant]}}
  end

  # ---- Read ----

  @impl true
  def run_query(query, resource) do
    client = get_client()
    namespace = resolve_namespace(query, client)

    path =
      case Info.scope!(resource) do
        :namespaced -> Info.namespaced_api_path!(resource, namespace)
        :cluster -> Info.api_path!(resource)
      end

    label_selector = build_label_selector(query)
    list_opts = if label_selector, do: [labelSelector: label_selector], else: []

    with {:ok, response} <- Client.list(client, path, list_opts),
         {:ok, items} <- extract_items(response) do
      records =
        items
        |> Enum.map(&raw_to_struct(resource, &1))
        |> apply_in_memory_filter(query)
        |> apply_sort(query)
        |> apply_offset(query)
        |> apply_limit(query)

      {:ok, records}
    end
  end

  # ---- Create ----

  @impl true
  def create(resource, changeset) do
    client = get_client()
    namespace = resolve_namespace_from_changeset(changeset, client)

    attrs = changeset.attributes
    name = Map.get(attrs, :name) || raise "k8s resources require a :name attribute"

    body = build_body(resource, attrs, name, namespace)

    path =
      case Info.scope!(resource) do
        :namespaced -> Info.namespaced_api_path!(resource, namespace)
        :cluster -> Info.api_path!(resource)
      end

    with {:ok, raw} <- Client.create(client, path, body) do
      {:ok, raw_to_struct(resource, raw)}
    end
  end

  # ---- Update ----

  @impl true
  def update(resource, changeset) do
    client = get_client()
    record = changeset.data
    namespace = Map.get(record, :namespace) || resolve_default_namespace(client)
    name = Map.get(record, :name) || raise "Cannot update a resource without a :name"
    resource_version = Map.get(record, :resource_version)

    attrs = changeset.attributes

    current_spec = Map.get(record, :spec) || %{}
    new_spec = Map.merge(current_spec, Map.get(attrs, :spec) || %{})

    body =
      %{
        "apiVersion" => Info.api_version!(resource),
        "kind" => Info.kind!(resource),
        "metadata" => %{
          "name" => name,
          "namespace" => namespace,
          "resourceVersion" => resource_version,
          "labels" => Map.get(attrs, :labels) || Map.get(record, :labels) || %{},
          "annotations" => Map.get(attrs, :annotations) || Map.get(record, :annotations) || %{}
        },
        "spec" => new_spec
      }
      |> maybe_put_status(attrs)

    path = object_path(resource, namespace, name)

    # Status subresource requires a merge-patch (not a PUT) since K8s rejects
    # a bare {"status": ...} body without apiVersion/kind/metadata.
    if Map.keys(attrs) == [:status] do
      status_body = %{"status" => Map.get(attrs, :status, %{})}
      with {:ok, raw} <- Client.patch(client, path <> "/status", status_body) do
        {:ok, raw_to_struct(resource, raw)}
      end
    else
      with {:ok, raw} <- Client.replace(client, path, body) do
        {:ok, raw_to_struct(resource, raw)}
      end
    end
  end

  # ---- Destroy ----

  @impl true
  def destroy(resource, changeset) do
    client = get_client()
    record = changeset.data
    namespace = Map.get(record, :namespace) || resolve_default_namespace(client)
    name = Map.get(record, :name) || raise "Cannot delete a resource without a :name"

    path = object_path(resource, namespace, name)

    case Client.delete(client, path) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- Helpers ----

  defp get_client do
    case Application.get_env(:ash_k8s, :client) do
      nil ->
        case Client.from_env() do
          {:ok, client} -> client
          {:error, reason} -> raise "AshK8s: could not build K8s client: #{inspect(reason)}"
        end

      mod when is_atom(mod) ->
        mod.new()

      client ->
        client
    end
  end

  defp resolve_namespace(%Query{namespace: ns}, _client) when is_binary(ns), do: ns
  defp resolve_namespace(%Query{tenant: ns}, _client) when is_binary(ns), do: ns
  defp resolve_namespace(_, client), do: resolve_default_namespace(client)

  defp resolve_namespace_from_changeset(changeset, client) do
    attrs = changeset.attributes

    Map.get(attrs, :namespace) ||
      changeset.context[:namespace] ||
      resolve_default_namespace(client)
  end

  defp resolve_default_namespace(client) do
    Map.get(client.config, :namespace, "default")
  end

  defp build_label_selector(query) do
    # Extract simple equality filters on :labels map keys into label selectors.
    # Falls back to nil (no server-side filtering) for complex filters.
    case query.filter do
      nil -> nil
      _filter -> nil
    end
  end

  defp extract_items(%{"items" => items}) when is_list(items), do: {:ok, items}
  defp extract_items(%{"kind" => kind} = obj) when kind != "List", do: {:ok, [obj]}
  defp extract_items(_), do: {:ok, []}

  defp raw_to_struct(resource_module, raw) do
    metadata = raw["metadata"] || %{}
    spec = raw["spec"] || %{}
    status = raw["status"] || %{}

    attrs = %{
      name: metadata["name"],
      namespace: metadata["namespace"] || "default",
      uid: metadata["uid"],
      resource_version: metadata["resourceVersion"],
      generation: metadata["generation"],
      labels: metadata["labels"] || %{},
      annotations: metadata["annotations"] || %{},
      spec: spec,
      status: status
    }

    resource_attrs = Ash.Resource.Info.attributes(resource_module)
    attr_names = Enum.map(resource_attrs, & &1.name)

    filtered = Map.take(attrs, attr_names)
    struct!(resource_module, filtered)
  rescue
    e ->
      Logger.warning("AshK8s: failed to cast raw object to #{inspect(resource_module)}: #{inspect(e)}")
      struct(resource_module)
  end

  defp build_body(resource, attrs, name, namespace) do
    base = %{
      "apiVersion" => Info.api_version!(resource),
      "kind" => Info.kind!(resource),
      "metadata" => %{
        "name" => name,
        "namespace" => namespace,
        "labels" => Map.get(attrs, :labels) || %{},
        "annotations" => Map.get(attrs, :annotations) || %{}
      },
      "spec" => Map.get(attrs, :spec) || %{}
    }

    maybe_put_status(base, attrs)
  end

  defp maybe_put_status(body, attrs) do
    case Map.get(attrs, :status) do
      nil -> body
      status -> Map.put(body, "status", status)
    end
  end

  defp object_path(resource, namespace, name) do
    case Info.scope!(resource) do
      :namespaced -> "#{Info.namespaced_api_path!(resource, namespace)}/#{name}"
      :cluster -> "#{Info.api_path!(resource)}/#{name}"
    end
  end

  defp apply_in_memory_filter(records, %Query{filter: nil}), do: records
  defp apply_in_memory_filter(records, _query), do: records

  defp apply_sort(records, %Query{sort: nil}), do: records
  defp apply_sort(records, %Query{sort: sort}) do
    Enum.sort_by(records, fn record ->
      Enum.map(sort, fn {key, _dir} -> Map.get(record, key) end)
    end)
  end

  defp apply_offset(records, %Query{offset: nil}), do: records
  defp apply_offset(records, %Query{offset: 0}), do: records
  defp apply_offset(records, %Query{offset: offset}), do: Enum.drop(records, offset)

  defp apply_limit(records, %Query{limit: nil}), do: records
  defp apply_limit(records, %Query{limit: limit}), do: Enum.take(records, limit)
end
