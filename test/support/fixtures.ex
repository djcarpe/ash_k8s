defmodule AshK8s.Test.Fixtures do
  @moduledoc false

  def widget_raw(overrides \\ %{}) do
    Map.merge(
      %{
        "apiVersion" => "widgets.example.com/v1",
        "kind" => "Widget",
        "metadata" => %{
          "name" => "my-widget",
          "namespace" => "default",
          "uid" => "abc-123",
          "resourceVersion" => "12345",
          "generation" => 1,
          "labels" => %{"app" => "my-app"},
          "annotations" => %{}
        },
        "spec" => %{"replicas" => 2, "image" => "nginx:latest"},
        "status" => %{"phase" => "Running"}
      },
      overrides
    )
  end

  def widget_list(items \\ []) do
    %{
      "apiVersion" => "widgets.example.com/v1",
      "kind" => "WidgetList",
      "metadata" => %{"resourceVersion" => "99999"},
      "items" => Enum.map(items, &widget_raw/1)
    }
  end

  def watch_event(type, raw_object) do
    Jason.encode!(%{"type" => to_string(type) |> String.upcase(), "object" => raw_object})
  end
end
