defmodule AshK8s.DataLayer.Query do
  @moduledoc false

  defstruct [
    :resource,
    :filter,
    :sort,
    :limit,
    :offset,
    :namespace,
    :label_selector,
    :field_selector,
    tenant: nil
  ]
end
