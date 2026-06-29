defmodule AshK8s.ManagedResources do
  @moduledoc """
  Spark DSL extension that provides pre-built, versioned Ash resource modules
  for all standard Kubernetes resource types — similar to how Tanka does for Jsonnet.

  Add this extension to an `Ash.Domain` alongside `AshK8s.Operator` and declare
  resources inline instead of writing a separate module file for each one:

      defmodule MyApp.K8s do
        use Ash.Domain,
          extensions: [AshK8s.Operator, AshK8s.ManagedResources],
          validate_config_inclusion?: false

        operator do
          name      "my-operator"
          namespace "default"
        end

        managed_resources do
          service do
            controller MyApp.Controllers.ServiceController
          end

          deployment do
            controller MyApp.Controllers.DeploymentController
            column "READY", json_path: ".status.readyReplicas"
            column "AGE",   json_path: ".metadata.creationTimestamp", type: "date"
          end

          ingress do
            controller MyApp.Controllers.IngressController
          end
        end
      end

  The above generates `MyApp.K8s.Service`, `MyApp.K8s.Deployment`, and
  `MyApp.K8s.Ingress` at compile time, registers them in the domain's
  `resources` block, and — because `AshK8s.Operator` is present and each
  declaration includes a `controller` — also wires them into the operator's
  `watches` block automatically.

  ## Options per resource

  | Option       | Type   | Description                                                    |
  |-------------|--------|----------------------------------------------------------------|
  | `controller` | module | Controller implementing `AshK8s.Controller.Behaviour`.        |
  | `module`     | atom   | Override the generated module name (default: `Domain.Kind`).  |

  ## Supported resource types

  All 29 standard K8s resource types are built in.  See
  `AshK8s.ManagedResources.Catalog` for the full list with API metadata.

  ## Customising printer columns

  `column` declarations go directly inside the resource block — there is no
  wrapper section:

      deployment do
        controller MyApp.Controllers.DeploymentController
        column "READY",    json_path: ".status.readyReplicas"
        column "REPLICAS", json_path: ".spec.replicas"
        column "AGE",      json_path: ".metadata.creationTimestamp", type: "date"
      end
  """

  alias AshK8s.ManagedResources.{Catalog, Entities}

  @printer_column %Spark.Dsl.Entity{
    name: :column,
    describe: "A column shown by `kubectl get`.",
    args: [:name],
    target: Entities.PrinterColumn,
    schema: [
      name: [type: :string, required: true, doc: "Column header."],
      json_path: [type: :string, required: true, doc: "JSONPath into the resource."],
      type: [
        type: {:one_of, ["integer", "number", "string", "boolean", "date"]},
        default: "string",
        doc: "Column data type."
      ],
      format: [type: :string, doc: "OpenAPI format (e.g. `date-time`)."],
      description: [type: :string, doc: "Column description."],
      priority: [type: :integer, default: 0, doc: "0 = always shown, >0 = wide only."]
    ]
  }

  # One Spark entity per catalog entry — evaluated at extension compile time.
  resource_entities =
    Enum.map(Catalog.all(), fn entry ->
      group_label = if entry.group == "", do: "core", else: entry.group

      %Spark.Dsl.Entity{
        name: entry.name,
        describe: "Managed #{entry.kind} (#{group_label}/#{entry.version}, #{entry.scope}).",
        target: Entities.ManagedResource,
        schema: [
          kind: [type: :atom, default: entry.name, doc: "Resource type (auto-set)."],
          controller: [type: :atom, doc: "Controller implementing `AshK8s.Controller.Behaviour`."],
          module: [type: :atom, doc: "Override the generated module name (default: Domain.Kind)."]
        ],
        entities: [printer_columns: [@printer_column]]
      }
    end)

  @managed_resources %Spark.Dsl.Section{
    name: :managed_resources,
    describe: "Declare standard Kubernetes resources inline without writing separate modules.",
    entities: resource_entities
  }

  use Spark.Dsl.Extension,
    sections: [@managed_resources],
    transformers: [AshK8s.ManagedResources.Transformer]
end
