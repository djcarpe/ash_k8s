defmodule AshK8s.ControllerServerTelemetryTest do
  use ExUnit.Case, async: false

  alias AshK8s.Controller.Server

  defmodule OkController do
    def reconcile(_record, _context, _opts), do: :ok
  end

  defmodule ErrorController do
    def reconcile(_record, _context, _opts), do: {:error, "boom"}
    def finalize(_record, _context, _opts), do: {:error, "cleanup failed"}
  end

  defp state(controller) do
    %{
      resource: AshK8s.Test.Widget,
      kind: "Widget",
      controller: controller,
      domain: AshK8s.Test.WidgetDomain,
      client: :no_client_needed,
      watch_opts: []
    }
  end

  defp object do
    %{
      "metadata" => %{"name" => "w1", "namespace" => "mars"},
      "spec" => %{"size" => 1}
    }
  end

  test "reconcile emits start/stop telemetry with kind and result" do
    :telemetry_test.attach_event_handlers(self(), [
      [:ash_k8s, :reconcile, :start],
      [:ash_k8s, :reconcile, :stop]
    ])

    assert Server.run_reconcile(state(OkController), object(), "mars/w1", :added) == :ok

    assert_receive {[:ash_k8s, :reconcile, :start], _ref, %{system_time: _},
                    %{kind: "Widget", namespace: "mars", name: "w1", event_type: :added}}

    assert_receive {[:ash_k8s, :reconcile, :stop], _ref, %{duration: _},
                    %{kind: "Widget", result: :ok}}
  end

  test "failed reconcile reports result :error" do
    :telemetry_test.attach_event_handlers(self(), [[:ash_k8s, :reconcile, :stop]])

    assert Server.run_reconcile(state(ErrorController), object(), "mars/w1", :modified) ==
             {:error, "boom"}

    assert_receive {[:ash_k8s, :reconcile, :stop], _ref, _, %{result: :error}}
  end

  test "finalize emits start/stop telemetry" do
    :telemetry_test.attach_event_handlers(self(), [
      [:ash_k8s, :finalize, :start],
      [:ash_k8s, :finalize, :stop]
    ])

    # Error result avoids the finalizer-removal patch (no client in tests).
    assert Server.run_finalize(state(ErrorController), object(), "mars/w1") ==
             {:error, "cleanup failed"}

    assert_receive {[:ash_k8s, :finalize, :start], _ref, _, %{kind: "Widget", name: "w1"}}
    assert_receive {[:ash_k8s, :finalize, :stop], _ref, %{duration: _}, %{result: :error}}
  end
end
