defmodule AshK8s.Controller do
  @moduledoc """
  `use AshK8s.Controller` to implement a resource controller.

  A controller is a module that implements `AshK8s.Controller.Behaviour` and
  is registered in the operator's `watches` DSL block. The operator supervisor
  starts a `AshK8s.Controller.Server` for each registered controller.

  ## Usage

      defmodule MyApp.Controllers.WidgetController do
        use AshK8s.Controller, resource: MyApp.Widgets.Widget

        @impl true
        def reconcile(%MyApp.Widgets.Widget{} = widget, context, _opts) do
          # Ensure the underlying Deployment exists
          desired = build_deployment(widget)

          case Ash.create(MyApp.Deployments.Deployment, desired, domain: context.domain) do
            {:ok, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def finalize(%MyApp.Widgets.Widget{} = widget, context, _opts) do
          # Clean up external resources before the CR is deleted.
          :ok
        end

        defp build_deployment(widget) do
          # ... build a map for the desired Deployment spec
        end
      end

  ## Reconcile Return Values

    - `:ok` — resource successfully reconciled
    - `{:ok, map()}` — reconciled, map is ignored (for compatibility)
    - `{:requeue, ms}` — requeue after `ms` milliseconds (e.g. `{:requeue, 5_000}`)
    - `{:error, reason}` — log error and requeue with the default delay

  ## Finalizers

  If `finalize/3` is implemented, the controller automatically adds a finalizer
  to each resource it manages. The finalizer is removed only after `finalize/3`
  returns `:ok`. While the finalizer is present, Kubernetes will not delete the
  underlying object.
  """

  @doc false
  defmacro __using__(opts) do
    resource = Keyword.fetch!(opts, :resource)

    quote do
      @behaviour AshK8s.Controller.Behaviour

      @ash_k8s_resource unquote(resource)

      def __ash_k8s_resource__, do: @ash_k8s_resource

      # NOTE: no default finalize/3 is injected on purpose. Exporting
      # finalize/3 is what makes the server add a finalizer to every watched
      # object, and a finalizer blocks deletion whenever the operator is
      # down. Controllers opt in by implementing finalize/3 themselves.

      def child_spec(opts) do
        AshK8s.Controller.Server.child_spec(
          Keyword.merge(opts,
            resource: @ash_k8s_resource,
            controller: __MODULE__
          )
        )
      end
    end
  end
end
