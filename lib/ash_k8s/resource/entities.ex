defmodule AshK8s.Resource.Entities do
  @moduledoc false

  defmodule PrinterColumn do
    @moduledoc false
    defstruct [:name, :json_path, :type, :description, :priority, :format, :__spark_metadata__]
  end

  defmodule StatusCondition do
    @moduledoc false
    defstruct [:type, :description, :__spark_metadata__]
  end
end
