defmodule AshK8s.Operator do
  @moduledoc """
  Spark DSL extension that turns an Ash domain into a Kubernetes operator.

  The domain becomes the operator: it supervises watch loops for each registered
  resource and routes reconciliation events to the configured controllers.

  ## Usage

      defmodule MyApp.Widgets do
        use Ash.Domain, extensions: [AshK8s.Operator]

        operator do
          name              "widget-operator"
          namespace         "default"
          leader_election?  true

          watches do
            watch MyApp.Widgets.Widget,
              controller: MyApp.Controllers.WidgetController,
              reconcile_timeout: :timer.seconds(30),
              max_concurrent_reconciles: 5
          end
        end

        resources do
          resource MyApp.Widgets.Widget
        end
      end

  ## Starting the Operator

  Add it to your supervision tree:

      children = [
        {AshK8s.Operator.Supervisor, domain: MyApp.Widgets}
      ]

  Or start via `Mix.Tasks.AshK8s.Operator.Start`.
  """

  alias AshK8s.Operator.Entities.Watch

  @watch %Spark.Dsl.Entity{
    name: :watch,
    describe: "Register a resource and its controller with the operator.",
    args: [:resource],
    target: Watch,
    schema: [
      resource: [
        type: {:spark, Ash.Resource},
        required: true,
        doc: "The Ash resource (must use `AshK8s.Resource` extension)."
      ],
      controller: [
        type: :atom,
        required: true,
        doc: "Module implementing `AshK8s.Controller.Behaviour`."
      ],
      reconcile_timeout: [
        type: :pos_integer,
        default: 30_000,
        doc: "Max ms allowed per reconcile call before it is cancelled."
      ],
      max_concurrent_reconciles: [
        type: :pos_integer,
        default: 1,
        doc: "How many concurrent reconcile calls are allowed per resource."
      ],
      requeue_on_error_delay: [
        type: :pos_integer,
        default: 5_000,
        doc: "Ms to wait before requeuing a failed reconcile."
      ]
    ]
  }

  @watches %Spark.Dsl.Section{
    name: :watches,
    describe: "Resources to watch and their controllers.",
    entities: [@watch]
  }

  @operator %Spark.Dsl.Section{
    name: :operator,
    describe: "Operator-level configuration for this domain.",
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Operator name (used for leader election lease name)."
      ],
      namespace: [
        type: :string,
        default: "default",
        doc: "Namespace in which the operator runs and holds its lease."
      ],
      leader_election?: [
        type: :boolean,
        default: false,
        doc: "Enable leader election via a Kubernetes Lease object."
      ],
      lease_duration: [
        type: :pos_integer,
        default: 15_000,
        doc: "Leader lease duration in ms."
      ],
      renew_deadline: [
        type: :pos_integer,
        default: 10_000,
        doc: "Leader lease renewal deadline in ms."
      ],
      retry_period: [
        type: :pos_integer,
        default: 2_000,
        doc: "How often a non-leader tries to acquire the lease."
      ]
    ],
    sections: [@watches]
  }

  use Spark.Dsl.Extension,
    sections: [@operator],
    transformers: [],
    verifiers: [AshK8s.Operator.Verifiers.ValidateWatches]
end
