defmodule AshK8s.ControllerServerFinalizerTest do
  use ExUnit.Case, async: true

  alias AshK8s.Controller.Server

  defmodule FinalizingController do
    def reconcile(_record, _context, _opts), do: :ok
    def finalize(_record, _context, _opts), do: :ok
  end

  defmodule PlainController do
    def reconcile(_record, _context, _opts), do: :ok
  end

  defmodule MacroController do
    use AshK8s.Controller, resource: AshK8s.Test.Widget

    @impl true
    def reconcile(_record, _context, _opts), do: :ok
  end

  # finalizer name derives from the controller module's last segment
  @finalizer "ash-k8s.io/finalizing_controller"

  defp object(attrs) do
    %{"metadata" => Map.merge(%{"name" => "w", "namespace" => "default"}, attrs)}
  end

  test "adds the finalizer before first reconcile when controller finalizes" do
    assert Server.finalizer_action(FinalizingController, object(%{})) == :add_finalizer
  end

  test "reconciles normally once the finalizer is present" do
    assert Server.finalizer_action(FinalizingController, object(%{"finalizers" => [@finalizer]})) ==
             :reconcile
  end

  test "runs finalize when deletion is pending and our finalizer is present" do
    obj =
      object(%{
        "deletionTimestamp" => "2026-07-06T00:00:00Z",
        "finalizers" => [@finalizer]
      })

    assert Server.finalizer_action(FinalizingController, obj) == :finalize
  end

  test "skips finalize when deletion is pending without our finalizer" do
    obj = object(%{"deletionTimestamp" => "2026-07-06T00:00:00Z"})
    assert Server.finalizer_action(FinalizingController, obj) == :skip_deleted
  end

  test "controllers without finalize/3 never get a finalizer added" do
    assert Server.finalizer_action(PlainController, object(%{})) == :reconcile
  end

  test "use AshK8s.Controller does not inject a default finalize/3" do
    # A default finalize would make every controller finalizable, adding a
    # deletion-blocking finalizer to every watched object.
    refute function_exported?(MacroController, :finalize, 3)
    assert Server.finalizer_action(MacroController, object(%{})) == :reconcile
  end
end
