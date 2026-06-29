defmodule AshK8s.Operator.Entities do
  @moduledoc false

  defmodule Watch do
    @moduledoc false
    defstruct [
      :resource,
      :controller,
      :reconcile_timeout,
      :max_concurrent_reconciles,
      :requeue_on_error_delay,
      :__spark_metadata__
    ]
  end
end
