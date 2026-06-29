defmodule AshK8s.Test.Widget do
  @moduledoc false

  use Ash.Resource,
    domain: AshK8s.Test.WidgetDomain,
    extensions: [AshK8s.Resource],
    data_layer: AshK8s.DataLayer

  k8s do
    group "widgets.example.com"
    version "v1"
    scope :namespaced
    short_names ["w", "wg"]
    categories ["all"]

    printer_columns do
      column "PHASE", json_path: ".status.phase"
      column "REPLICAS", json_path: ".spec.replicas", type: "integer"
      column "AGE", json_path: ".metadata.creationTimestamp", type: "date"
    end

    status do
      enabled true
      condition "Ready", description: "Widget is reconciled"
      condition "Degraded", description: "Widget has errors"
    end
  end
end

defmodule AshK8s.Test.WidgetDomain do
  @moduledoc false

  use Ash.Domain,
    extensions: [AshK8s.Operator],
    validate_config_inclusion?: false

  operator do
    name "widget-operator"
    namespace "default"
    leader_election? false

    watches do
      watch AshK8s.Test.Widget,
        controller: AshK8s.Test.WidgetController
    end
  end

  resources do
    resource AshK8s.Test.Widget
  end
end

defmodule AshK8s.Test.WidgetController do
  @moduledoc false

  use AshK8s.Controller, resource: AshK8s.Test.Widget

  @impl true
  def reconcile(_widget, _context, _opts), do: :ok
end
