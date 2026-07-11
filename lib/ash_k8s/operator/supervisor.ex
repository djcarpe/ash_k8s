defmodule AshK8s.Operator.Supervisor do
  @moduledoc """
  Supervision tree for an AshK8s operator domain.

  Starts the Registry, leader election (if configured), and all controller
  servers registered in the domain's `operator > watches` DSL block.

  ## Usage

  Add to your application supervision tree:

      children = [
        {AshK8s.Operator.Supervisor, domain: MyApp.Widgets}
      ]

  Or start it manually:

      {:ok, _pid} = AshK8s.Operator.Supervisor.start_link(domain: MyApp.Widgets)

  You can also pass an explicit client:

      {:ok, config} = AshK8s.Client.Config.resolve()
      client = AshK8s.Client.new(config)

      {:ok, _pid} = AshK8s.Operator.Supervisor.start_link(
        domain: MyApp.Widgets,
        client: client
      )
  """

  use Supervisor

  alias AshK8s.{Client, Operator.Info, Operator.LeaderElection, Controller.Server}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(opts[:domain]))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:domain]},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    domain = Keyword.fetch!(opts, :domain)
    client = opts[:client] || resolve_client!()

    watches = Info.watches!(domain)
    op_name = Info.name!(domain)
    op_namespace = Info.namespace!(domain)
    leader_election? = Info.leader_election?(domain)

    leader_children =
      if leader_election? do
        [
          LeaderElection.child_spec(
            name: op_name,
            namespace: op_namespace,
            client: client,
            lease_duration:
              Spark.Dsl.Extension.get_opt(domain, [:operator], :lease_duration, 15_000),
            renew_deadline:
              Spark.Dsl.Extension.get_opt(domain, [:operator], :renew_deadline, 10_000),
            retry_period: Spark.Dsl.Extension.get_opt(domain, [:operator], :retry_period, 2_000),
            notify: self()
          )
        ]
      else
        []
      end

    controller_children =
      Enum.map(watches, fn watch ->
        Server.child_spec(
          resource: watch.resource,
          controller: watch.controller,
          domain: domain,
          client: client,
          watch_namespace: opts[:watch_namespace],
          max_concurrent_reconciles: watch.max_concurrent_reconciles,
          requeue_on_error_delay: watch.requeue_on_error_delay
        )
      end)

    children = leader_children ++ controller_children

    :telemetry.execute(
      [:ash_k8s, :operator, :init],
      %{watch_count: length(watches)},
      %{operator: op_name, domain: domain, leader_election: leader_election?}
    )

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp supervisor_name(domain), do: {:via, Registry, {AshK8s.Registry, {:supervisor, domain}}}

  defp resolve_client! do
    case Client.from_env() do
      {:ok, client} ->
        client

      {:error, reason} ->
        raise "AshK8s: could not resolve Kubernetes client config: #{inspect(reason)}"
    end
  end
end
