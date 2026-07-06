defmodule AshK8s.Controller.Server do
  @moduledoc """
  GenServer that drives a single resource controller.

  Starts a Kubernetes watch stream for one resource type and dispatches events
  to the configured `AshK8s.Controller.Behaviour` implementation. Handles
  finalizer negotiation, requeue backoffs, and watch reconnects.

  Normally started by `AshK8s.Operator.Supervisor`; you should not need to
  start it directly.
  """

  use GenServer, restart: :permanent

  require Logger

  alias AshK8s.{Client, Resource.Info}

  @type start_opts :: [
          resource: module(),
          controller: module(),
          domain: module(),
          client: Client.t(),
          opts: keyword()
        ]

  @finalizer_prefix "ash-k8s.io"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: server_name(opts[:resource]))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:resource]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    # Watch and reconcile tasks are linked (Task.async); trap exits so a
    # crashing task is handled via :DOWN instead of killing the server.
    Process.flag(:trap_exit, true)

    resource = opts[:resource]
    controller = opts[:controller]
    domain = opts[:domain]
    client = opts[:client]
    watch_opts = opts[:watch_opts] || []

    state = %{
      resource: resource,
      controller: controller,
      domain: domain,
      client: client,
      watch_opts: watch_opts,
      watch_namespace: opts[:watch_namespace],
      resource_version: "0",
      queue: :queue.new(),
      active_tasks: %{},
      max_concurrent: opts[:max_concurrent_reconciles] || 1
    }

    send(self(), :start_watch)
    {:ok, state}
  end

  @doc """
  Resolves the list/watch path for a resource given the configured watch
  namespace.

  - cluster-scoped resources always watch at the cluster path
  - `:all` (or `nil`) watches namespaced resources across all namespaces
  - a namespace string watches that namespace only
  """
  @spec watch_path(module(), :all | String.t() | nil) :: String.t()
  def watch_path(resource, watch_namespace) do
    case {Info.scope!(resource), watch_namespace} do
      {:cluster, _} -> Info.api_path!(resource)
      {:namespaced, ns} when is_binary(ns) -> Info.namespaced_api_path!(resource, ns)
      {:namespaced, _} -> Info.api_path!(resource)
    end
  end

  @impl true
  def handle_info(:start_watch, state) do
    path = watch_path(state.resource, state.watch_namespace)

    watch_opts = Keyword.merge(state.watch_opts, resource_version: state.resource_version)

    server_pid = self()

    # Run the watch in a dedicated Task so the GenServer stays responsive.
    # Capture server_pid before the Task — self() inside the Task is the Task's own PID.
    task =
      Task.async(fn ->
        state.client
        |> Client.watch(path, watch_opts)
        |> Stream.each(fn event -> send(server_pid, {:watch_event, event}) end)
        |> Stream.run()
      end)

    {:noreply, %{state | active_tasks: Map.put(state.active_tasks, task.ref, :watch)}}
  end

  @impl true
  def handle_info({:watch_event, {:bookmark, _object}}, state) do
    {:noreply, state}
  end

  def handle_info({:watch_event, {type, raw_object}}, state)
      when type in [:added, :modified, :deleted] do
    key = object_key(raw_object)
    state = enqueue(state, {type, raw_object, key})
    state = drain_queue(state)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.active_tasks, ref) do
      {{:reconcile, key, raw_object, _controller}, tasks} ->
        Process.demonitor(ref, [:flush])
        state = %{state | active_tasks: tasks}
        state = handle_reconcile_result(state, result, key, raw_object, nil)
        state = drain_queue(state)
        {:noreply, state}

      {:watch, tasks} ->
        Process.demonitor(ref, [:flush])
        # Watch task completed (stream exhausted) — restart
        send(self(), :start_watch)
        {:noreply, %{state | active_tasks: tasks}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.active_tasks, ref) do
      {{:reconcile, key, raw_object, _controller}, tasks} ->
        Logger.error("[AshK8s] Reconcile task crashed for #{key}: #{inspect(reason)}")
        state = %{state | active_tasks: tasks}
        schedule_requeue(key, raw_object, 5_000)
        state = drain_queue(state)
        {:noreply, state}

      {:watch, tasks} ->
        Logger.warning(
          "[AshK8s] Watch for #{inspect(state.resource)} failed: #{inspect(reason)} — retrying in 5s"
        )

        Process.send_after(self(), :start_watch, 5_000)
        {:noreply, %{state | active_tasks: tasks}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:requeue, key, raw_object}, state) do
    state = enqueue(state, {:modified, raw_object, key})
    state = drain_queue(state)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ---- Private helpers ----

  defp enqueue(state, event) do
    %{state | queue: :queue.in(event, state.queue)}
  end

  defp drain_queue(%{active_tasks: tasks, max_concurrent: max} = state) do
    reconcile_count =
      Enum.count(tasks, fn {_, v} -> match?({:reconcile, _, _, _}, v) end)

    if reconcile_count >= max do
      state
    else
      drain_queue_inner(state)
    end
  end

  defp drain_queue_inner(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {type, raw_object, key}}, queue} ->
        state = %{state | queue: queue}
        task = start_reconcile_task(state, type, raw_object, key)

        state = %{
          state
          | active_tasks:
              Map.put(
                state.active_tasks,
                task.ref,
                {:reconcile, key, raw_object, state.controller}
              )
        }

        drain_queue(state)
    end
  end

  defp start_reconcile_task(state, :deleted, _raw_object, key) do
    # The object is gone from the API server. Finalizer-based cleanup (if
    # any) already ran while the object carried a deletionTimestamp.
    Task.async(fn -> {:deleted, key} end)
  end

  defp start_reconcile_task(state, _type, raw_object, key) do
    case finalizer_action(state.controller, raw_object) do
      :finalize ->
        Task.async(fn -> run_finalize(state, raw_object, key) end)

      :skip_deleted ->
        Task.async(fn -> {:deleted, key} end)

      :add_finalizer ->
        Task.async(fn ->
          case add_finalizer(state, raw_object) do
            {:ok, _} -> run_reconcile(state, raw_object, key)
            {:error, reason} -> {:error, {:add_finalizer, reason}}
          end
        end)

      :reconcile ->
        Task.async(fn -> run_reconcile(state, raw_object, key) end)
    end
  end

  @doc false
  # Decides how to handle an :added/:modified event with respect to the
  # controller's finalizer:
  #
  #   * object being deleted + our finalizer present  -> :finalize
  #   * object being deleted, finalizer absent        -> :skip_deleted
  #   * controller finalizes but finalizer not yet on -> :add_finalizer
  #   * otherwise                                     -> :reconcile
  @spec finalizer_action(module(), map()) ::
          :finalize | :skip_deleted | :add_finalizer | :reconcile
  def finalizer_action(controller, raw_object) do
    finalizer = finalizer_name(controller)

    cond do
      get_in(raw_object, ["metadata", "deletionTimestamp"]) ->
        if has_finalizer?(raw_object, finalizer), do: :finalize, else: :skip_deleted

      finalizable?(controller) and not has_finalizer?(raw_object, finalizer) ->
        :add_finalizer

      true ->
        :reconcile
    end
  end

  defp finalizable?(controller) do
    Code.ensure_loaded?(controller) and function_exported?(controller, :finalize, 3)
  end

  defp run_reconcile(state, raw_object, _key) do
    resource_struct = raw_to_struct(state.resource, raw_object)

    context = %{
      domain: state.domain,
      client: state.client,
      namespace: get_in(raw_object, ["metadata", "namespace"]) || "default",
      opts: state.watch_opts
    }

    state.controller.reconcile(resource_struct, context, [])
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_finalize(state, raw_object, key) do
    resource_struct = raw_to_struct(state.resource, raw_object)

    context = %{
      domain: state.domain,
      client: state.client,
      namespace: get_in(raw_object, ["metadata", "namespace"]) || "default",
      opts: state.watch_opts
    }

    if function_exported?(state.controller, :finalize, 3) do
      case state.controller.finalize(resource_struct, context, []) do
        :ok -> remove_finalizer(state, raw_object, key)
        {:ok, _} -> remove_finalizer(state, raw_object, key)
        other -> other
      end
    else
      remove_finalizer(state, raw_object, key)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp handle_reconcile_result(state, :ok, _key, _raw_object, _controller), do: state
  defp handle_reconcile_result(state, {:ok, _}, _key, _raw_object, _controller), do: state

  defp handle_reconcile_result(state, {:deleted, _deleted_key}, _key, _raw_object, _controller),
    do: state

  defp handle_reconcile_result(state, {:requeue, delay}, key, raw_object, _controller) do
    schedule_requeue(key, raw_object, delay)
    state
  end

  defp handle_reconcile_result(state, {:error, reason}, key, raw_object, _controller) do
    Logger.warning("[AshK8s] Reconcile failed for #{key}: #{inspect(reason)}")
    schedule_requeue(key, raw_object, 5_000)
    state
  end

  defp schedule_requeue(key, raw_object, delay) do
    Process.send_after(self(), {:requeue, key, raw_object}, delay)
  end

  defp raw_to_struct(resource_module, raw_object) do
    metadata = raw_object["metadata"] || %{}
    spec = raw_object["spec"] || %{}
    status = raw_object["status"] || %{}

    attrs =
      Map.merge(
        %{
          name: metadata["name"],
          namespace: metadata["namespace"] || "default",
          uid: metadata["uid"],
          resource_version: metadata["resourceVersion"],
          generation: metadata["generation"],
          labels: metadata["labels"] || %{},
          annotations: metadata["annotations"] || %{},
          spec: spec,
          status: status
        },
        %{}
      )

    struct!(resource_module, attrs)
  rescue
    _ -> struct(resource_module, %{})
  end

  defp object_key(raw_object) do
    ns = get_in(raw_object, ["metadata", "namespace"])
    name = get_in(raw_object, ["metadata", "name"])
    if ns, do: "#{ns}/#{name}", else: name
  end

  defp finalizer_name(controller) do
    "#{@finalizer_prefix}/#{controller |> Module.split() |> List.last() |> Macro.underscore()}"
  end

  defp has_finalizer?(raw_object, finalizer) do
    finalizers = get_in(raw_object, ["metadata", "finalizers"]) || []
    finalizer in finalizers
  end

  defp add_finalizer(state, raw_object) do
    finalizer = finalizer_name(state.controller)
    metadata = raw_object["metadata"] || %{}
    patch_finalizers(state, metadata, (metadata["finalizers"] || []) ++ [finalizer])
  end

  defp remove_finalizer(state, raw_object, _key) do
    finalizer = finalizer_name(state.controller)
    metadata = raw_object["metadata"] || %{}
    patch_finalizers(state, metadata, (metadata["finalizers"] || []) -- [finalizer])
  end

  defp patch_finalizers(state, metadata, finalizers) do
    name = metadata["name"]
    namespace = metadata["namespace"]

    path =
      case Info.scope!(state.resource) do
        :namespaced ->
          "#{Info.namespaced_api_path!(state.resource, namespace)}/#{name}"

        :cluster ->
          "#{Info.api_path!(state.resource)}/#{name}"
      end

    patch_body = %{
      "metadata" => %{
        "finalizers" => finalizers,
        "resourceVersion" => metadata["resourceVersion"]
      }
    }

    Client.patch(state.client, path, patch_body)
  end

  defp server_name(resource), do: {:via, Registry, {AshK8s.Registry, {__MODULE__, resource}}}
end
