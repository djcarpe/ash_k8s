defmodule AshK8s.Controller.Behaviour do
  @moduledoc """
  Behaviour that every AshK8s controller must implement.

  A controller handles reconciliation for a single Ash resource type.
  It is called by `AshK8s.Controller.Server` whenever a watch event
  arrives for that resource.

  ## Example

      defmodule MyApp.Controllers.WidgetController do
        use AshK8s.Controller, resource: MyApp.Widgets.Widget

        @impl true
        def reconcile(widget, %{domain: MyApp.Widgets, client: client}, _opts) do
          # widget is an Ash.Resource struct loaded from the API.
          # Return :ok to mark reconciled, {:requeue, ms} to retry after delay,
          # or {:error, reason} to log and requeue with the default delay.
          :ok
        end

        @impl true
        def finalize(widget, %{domain: MyApp.Widgets, client: client}, _opts) do
          # Called before deletion when the resource has a finalizer managed
          # by this controller. Remove the finalizer when cleanup is done.
          :ok
        end
      end
  """

  @type resource_struct :: Ash.Resource.record()

  @type context :: %{
          domain: module(),
          client: AshK8s.Client.t(),
          namespace: String.t(),
          event_type: :added | :modified,
          opts: keyword()
        }

  @type reconcile_result ::
          :ok
          | {:ok, map()}
          | {:requeue, non_neg_integer()}
          | {:error, term()}

  @doc """
  Called for every `:added` and `:modified` watch event, and on operator start
  for any existing resources.

  `resource` is the Ash struct loaded from the Kubernetes API.
  `context` contains the domain, client, and any options.
  """
  @callback reconcile(resource_struct(), context(), keyword()) :: reconcile_result()

  @doc """
  Called before a resource is deleted when it has a finalizer owned by this
  controller. Must remove the finalizer once cleanup is complete.

  Returning `:ok` signals successful finalization; the controller will
  automatically remove the finalizer from the resource.

  Returning `{:error, reason}` keeps the finalizer in place and requeues.
  """
  @callback finalize(resource_struct(), context(), keyword()) :: reconcile_result()

  @optional_callbacks [finalize: 3]
end
