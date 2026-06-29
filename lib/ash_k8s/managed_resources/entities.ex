defmodule AshK8s.ManagedResources.Entities do
  @moduledoc false

  defmodule ManagedResource do
    @moduledoc false
    defstruct [:kind, :controller, :module, printer_columns: [], __spark_metadata__: nil]
  end

  defmodule PrinterColumn do
    @moduledoc false
    defstruct [:name, :json_path, :type, :description, :priority, :format, :__spark_metadata__]
  end
end
