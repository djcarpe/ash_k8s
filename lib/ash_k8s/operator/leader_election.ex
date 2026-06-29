defmodule AshK8s.Operator.LeaderElection do
  @moduledoc """
  Leader election via Kubernetes `Lease` objects (coordination.k8s.io/v1).

  Only one replica of the operator is the active leader; others watch the lease
  and take over when the holder fails to renew within the lease duration.

  The leader's status is broadcast via `Registry` under the key
  `{AshK8s.LeaderElection, operator_name}`.
  """

  use GenServer

  require Logger

  alias AshK8s.Client

  @lease_api "/apis/coordination.k8s.io/v1"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {AshK8s.Registry, {:leader_election, opts[:name]}}}
    )
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:name]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc "Returns true if this process is currently the leader."
  @spec leader?(String.t()) :: boolean()
  def leader?(operator_name) do
    case Registry.lookup(AshK8s.Registry, {:is_leader, operator_name}) do
      [{_pid, true}] -> true
      _ -> false
    end
  end

  # ---- GenServer callbacks ----

  @impl true
  def init(opts) do
    state = %{
      name: opts[:name],
      namespace: opts[:namespace] || "default",
      client: opts[:client],
      lease_duration: opts[:lease_duration] || 15_000,
      renew_deadline: opts[:renew_deadline] || 10_000,
      retry_period: opts[:retry_period] || 2_000,
      holder_identity: node_identity(),
      is_leader: false,
      notify: opts[:notify]
    }

    send(self(), :try_acquire)
    {:ok, state}
  end

  @impl true
  def handle_info(:try_acquire, state) do
    case acquire_or_renew(state) do
      {:ok, :leader} ->
        if not state.is_leader do
          Logger.info("[AshK8s] #{state.name}: became leader (#{state.holder_identity})")
          if state.notify, do: send(state.notify, {:leader_elected, state.name})
        end

        register_leader_status(state.name, true)
        schedule(state.renew_deadline)
        {:noreply, %{state | is_leader: true}}

      {:ok, :follower} ->
        if state.is_leader do
          Logger.warning("[AshK8s] #{state.name}: lost leadership")
          if state.notify, do: send(state.notify, {:leader_lost, state.name})
        end

        register_leader_status(state.name, false)
        schedule(state.retry_period)
        {:noreply, %{state | is_leader: false}}

      {:error, reason} ->
        Logger.warning("[AshK8s] #{state.name}: lease error #{inspect(reason)}")
        register_leader_status(state.name, false)
        schedule(state.retry_period)
        {:noreply, %{state | is_leader: false}}
    end
  end

  defp acquire_or_renew(state) do
    lease_path = "#{@lease_api}/namespaces/#{state.namespace}/leases/#{lease_name(state.name)}"
    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()
    duration_s = div(state.lease_duration, 1000)

    case Client.get(state.client, lease_path) do
      {:ok, lease} ->
        handle_existing_lease(state, lease, lease_path, now_iso, duration_s)

      {:error, {:k8s_error, 404, _}} ->
        create_lease(state, lease_path, now_iso, duration_s)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_existing_lease(state, lease, lease_path, now_iso, duration_s) do
    spec = lease["spec"] || %{}
    holder = spec["holderIdentity"]
    renew_time = spec["renewTime"]
    lease_duration = (spec["leaseDurationSeconds"] || div(state.lease_duration, 1000)) * 1000

    expired? =
      case renew_time && DateTime.from_iso8601(renew_time) do
        {:ok, dt, _} ->
          DateTime.diff(DateTime.utc_now(), dt, :millisecond) > lease_duration

        _ ->
          true
      end

    if holder == state.holder_identity or expired? do
      body = %{
        "metadata" => %{
          "resourceVersion" => get_in(lease, ["metadata", "resourceVersion"])
        },
        "spec" => %{
          "holderIdentity" => state.holder_identity,
          "leaseDurationSeconds" => duration_s,
          "renewTime" => now_iso,
          "acquireTime" => if(holder != state.holder_identity, do: now_iso, else: spec["acquireTime"])
        }
      }

      case Client.patch(state.client, lease_path, body) do
        {:ok, _} -> {:ok, :leader}
        {:error, {:k8s_error, 409, _}} -> {:ok, :follower}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, :follower}
    end
  end

  defp create_lease(state, _lease_path, now_iso, duration_s) do
    body = %{
      "apiVersion" => "coordination.k8s.io/v1",
      "kind" => "Lease",
      "metadata" => %{
        "name" => lease_name(state.name),
        "namespace" => state.namespace
      },
      "spec" => %{
        "holderIdentity" => state.holder_identity,
        "leaseDurationSeconds" => duration_s,
        "acquireTime" => now_iso,
        "renewTime" => now_iso
      }
    }

    base_path = "#{@lease_api}/namespaces/#{state.namespace}/leases"

    case Client.create(state.client, base_path, body) do
      {:ok, _} -> {:ok, :leader}
      {:error, {:k8s_error, 409, _}} -> {:ok, :follower}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule(delay), do: Process.send_after(self(), :try_acquire, delay)

  defp lease_name(operator_name) do
    operator_name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\-]/, "-")
  end

  defp node_identity, do: "#{node()}-#{:os.getpid()}"

  defp register_leader_status(name, value) do
    Registry.register(AshK8s.Registry, {:is_leader, name}, value)
  rescue
    _ -> Registry.update_value(AshK8s.Registry, {:is_leader, name}, fn _ -> value end)
  end
end
