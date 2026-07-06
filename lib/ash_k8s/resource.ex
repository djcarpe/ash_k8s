defmodule AshK8s.Resource do
  @moduledoc """
  Spark DSL extension that maps an Ash resource to a Kubernetes CRD.

  Add this extension to any Ash resource to describe its CRD shape, then pair it
  with `AshK8s.DataLayer` to back actions against the live Kubernetes API.

  ## Usage

      defmodule MyApp.Widgets.Widget do
        use Ash.Resource,
          domain: MyApp.Widgets,
          extensions: [AshK8s.Resource],
          data_layer: AshK8s.DataLayer

        k8s do
          group    "widgets.example.com"
          version  "v1"
          scope    :namespaced

          printer_columns do
            column "PHASE", json_path: ".status.phase"
            column "AGE",   json_path: ".metadata.creationTimestamp", type: "date"
          end

          status do
            condition "Ready",   description: "Widget is fully reconciled"
            condition "Degraded", description: "Widget encountered an error"
          end
        end

        attributes do
          uuid_primary_key :id

          attribute :name,             :string,  allow_nil?: false, public?: true
          attribute :namespace,        :string,  allow_nil?: false, public?: true
          attribute :spec,             :map,     allow_nil?: false, public?: true
          attribute :status,           :map,     default: %{},      public?: true
          attribute :labels,           :map,     default: %{},      public?: true
          attribute :annotations,      :map,     default: %{},      public?: true
          attribute :resource_version, :string,  public?: true
          attribute :generation,       :integer, public?: true
          attribute :uid,              :string,  public?: true
        end

        actions do
          defaults [:read, :destroy]

          create :create do
            accept [:name, :namespace, :spec, :labels, :annotations]
          end

          update :update do
            accept [:spec, :labels, :annotations]
          end

          update :patch_status do
            accept [:status]
          end
        end
      end

  ## CRD Generation

      AshK8s.CRD.generate(MyApp.Widgets.Widget) |> AshK8s.CRD.to_yaml()
  """

  alias AshK8s.Resource.Entities.{PrinterColumn, StatusCondition}

  @printer_column %Spark.Dsl.Entity{
    name: :column,
    describe: "A column shown by `kubectl get`.",
    args: [:name],
    target: PrinterColumn,
    schema: [
      name: [type: :string, required: true, doc: "Column header."],
      json_path: [type: :string, required: true, doc: "JSONPath into the CR."],
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

  @printer_columns %Spark.Dsl.Section{
    name: :printer_columns,
    describe: "kubectl printer columns for this CRD.",
    entities: [@printer_column]
  }

  @status_condition %Spark.Dsl.Entity{
    name: :condition,
    describe: "A status condition type.",
    args: [:type],
    target: StatusCondition,
    schema: [
      type: [type: :string, required: true, doc: "Condition type (e.g. `Ready`)."],
      description: [type: :string, doc: "Condition description."]
    ]
  }

  @status_section %Spark.Dsl.Section{
    name: :status,
    describe: "Status subresource configuration.",
    schema: [
      enabled: [type: :boolean, default: true, doc: "Enable the `/status` subresource."]
    ],
    entities: [@status_condition]
  }

  @k8s %Spark.Dsl.Section{
    name: :k8s,
    describe: "Kubernetes CRD configuration for this Ash resource.",
    schema: [
      group: [
        type: :string,
        required: true,
        doc:
          "API group (e.g. `apps.example.com`). Use `\"\"` for the core Kubernetes API group (`/api/v1`)."
      ],
      version: [type: :string, default: "v1", doc: "API version."],
      scope: [
        type: {:one_of, [:namespaced, :cluster]},
        default: :namespaced,
        doc: "Namespaced or cluster-scoped."
      ],
      plural: [type: :string, doc: "Plural name. Defaults to lowercased module name + 's'."],
      singular: [type: :string, doc: "Singular name. Defaults to lowercased module name."],
      kind: [type: :string, doc: "Kind. Defaults to last module name segment."],
      short_names: [type: {:list, :string}, default: [], doc: "kubectl short names."],
      categories: [type: {:list, :string}, default: [], doc: "CRD categories."],
      storage: [type: :boolean, default: true, doc: "Mark this version as the storage version."]
    ],
    sections: [@printer_columns, @status_section]
  }

  use Spark.Dsl.Extension,
    sections: [@k8s],
    transformers: [
      AshK8s.Resource.Transformers.SetDefaults,
      AshK8s.Resource.Transformers.InjectBaseSchema
    ],
    verifiers: [AshK8s.Resource.Verifiers.ValidateK8s]
end
