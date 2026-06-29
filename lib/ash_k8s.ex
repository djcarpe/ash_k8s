defmodule AshK8s do
  @moduledoc """
  Kubernetes operator and CRD framework built on Ash.

  AshK8s maps Ash concepts to Kubernetes operator concepts:

  | Ash concept         | Kubernetes concept          |
  |---------------------|-----------------------------|
  | `Ash.Resource`      | Custom Resource (CR / CRD)  |
  | `Ash.Domain`        | Operator                    |
  | Controller module   | Controller / Reconciler     |
  | `AshK8s.DataLayer`  | API-server backed storage   |

  ## Quick start

  ### 1. Define a resource (CRD)

      defmodule MyApp.Widgets.Widget do
        use Ash.Resource,
          domain: MyApp.Widgets,
          extensions: [AshK8s.Resource],
          data_layer: AshK8s.DataLayer

        k8s do
          group   "widgets.example.com"
          version "v1"
          scope   :namespaced

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
          attribute :name,      :string, allow_nil?: false, public?: true
          attribute :namespace, :string, allow_nil?: false, public?: true
          attribute :spec,      :map,    allow_nil?: false, public?: true
          attribute :status,    :map,    default: %{},      public?: true
          attribute :labels,    :map,    default: %{},      public?: true
          attribute :annotations, :map,  default: %{},      public?: true
          attribute :resource_version, :string, public?: true
          attribute :uid,              :string, public?: true
          attribute :generation,       :integer, public?: true
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

  ### 2. Implement a controller

      defmodule MyApp.Controllers.WidgetController do
        use AshK8s.Controller, resource: MyApp.Widgets.Widget

        @impl true
        def reconcile(%MyApp.Widgets.Widget{} = widget, _context, _opts) do
          # Your reconciliation logic here
          :ok
        end
      end

  ### 3. Configure the operator (domain)

      defmodule MyApp.Widgets do
        use Ash.Domain, extensions: [AshK8s.Operator]

        operator do
          name             "widget-operator"
          namespace        "default"
          leader_election? true

          watches do
            watch MyApp.Widgets.Widget,
              controller: MyApp.Controllers.WidgetController
          end
        end

        resources do
          resource MyApp.Widgets.Widget
        end
      end

  ### 4. Add the operator to your supervision tree

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {AshK8s.Operator.Supervisor, domain: MyApp.Widgets}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ### 5. Generate CRDs

      # In code:
      AshK8s.CRD.generate_yaml(MyApp.Widgets.Widget)

      # Via Mix task:
      mix ash_k8s.gen.crds

  ## Modules

  - `AshK8s.Resource` — Spark extension: adds `k8s` DSL block to resources
  - `AshK8s.Operator` — Spark extension: adds `operator` DSL block to domains
  - `AshK8s.Controller` — `use` macro for controller modules
  - `AshK8s.Controller.Behaviour` — callbacks: `reconcile/3`, `finalize/3`
  - `AshK8s.DataLayer` — Ash data layer that reads/writes from the K8s API
  - `AshK8s.CRD` — CRD YAML generation
  - `AshK8s.Client` — Low-level K8s API client
  - `AshK8s.Client.Config` — kubeconfig / in-cluster config resolution
  - `AshK8s.Client.Watch` — Kubernetes watch stream
  - `AshK8s.Operator.Supervisor` — operator supervision tree
  - `AshK8s.Operator.LeaderElection` — Lease-based leader election
  - `AshK8s.Resource.Info` — resource introspection helpers
  - `AshK8s.Operator.Info` — operator introspection helpers
  """
end
