#!/usr/bin/env elixir
# mix run examples/deploy_nginx.exs
#
# Deploys an nginx Deployment + Service + Ingress to k3d (k3s-in-Docker)
# using AshK8s resources backed by the Kubernetes API.

# ──────────────────────────────────────────────────────────────────────────
# Shared attribute + action boilerplate for K8s resources
# ──────────────────────────────────────────────────────────────────────────

defmodule Demo.K8s.Mixins do
  defmacro k8s_attributes do
    quote do
      attributes do
        uuid_primary_key :id
        attribute :name,             :string,  allow_nil?: false, public?: true
        attribute :namespace,        :string,  default: "default", public?: true
        attribute :spec,             :map,     default: %{},       public?: true
        attribute :status,           :map,     default: %{},       public?: true
        attribute :labels,           :map,     default: %{},       public?: true
        attribute :annotations,      :map,     default: %{},       public?: true
        attribute :resource_version, :string,  public?: true
        attribute :uid,              :string,  public?: true
        attribute :generation,       :integer, public?: true
      end
    end
  end

  defmacro k8s_actions do
    quote do
      actions do
        defaults [:read, :destroy]

        create :create do
          primary? true
          accept [:name, :namespace, :spec, :labels, :annotations]
        end

        update :update do
          primary? true
          accept [:spec, :labels, :annotations]
        end

        update :patch_status do
          accept [:status]
        end
      end
    end
  end
end

# ──────────────────────────────────────────────────────────────────────────
# Resource definitions — built-in Kubernetes types
# ──────────────────────────────────────────────────────────────────────────

defmodule Demo.K8s.Deployment do
  use Ash.Resource,
    domain: Demo.K8s,
    extensions: [AshK8s.Resource],
    data_layer: AshK8s.DataLayer

  k8s do
    group    "apps"
    version  "v1"
    plural   "deployments"
    singular "deployment"
    kind     "Deployment"
    scope    :namespaced
  end

  require Demo.K8s.Mixins
  Demo.K8s.Mixins.k8s_attributes()
  Demo.K8s.Mixins.k8s_actions()
end

defmodule Demo.K8s.Service do
  use Ash.Resource,
    domain: Demo.K8s,
    extensions: [AshK8s.Resource],
    data_layer: AshK8s.DataLayer

  k8s do
    group    ""
    version  "v1"
    plural   "services"
    singular "service"
    kind     "Service"
    scope    :namespaced
  end

  require Demo.K8s.Mixins
  Demo.K8s.Mixins.k8s_attributes()
  Demo.K8s.Mixins.k8s_actions()
end

defmodule Demo.K8s.Ingress do
  use Ash.Resource,
    domain: Demo.K8s,
    extensions: [AshK8s.Resource],
    data_layer: AshK8s.DataLayer

  k8s do
    group    "networking.k8s.io"
    version  "v1"
    plural   "ingresses"
    singular "ingress"
    kind     "Ingress"
    scope    :namespaced
  end

  require Demo.K8s.Mixins
  Demo.K8s.Mixins.k8s_attributes()
  Demo.K8s.Mixins.k8s_actions()
end

defmodule Demo.K8s do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Demo.K8s.Deployment
    resource Demo.K8s.Service
    resource Demo.K8s.Ingress
  end
end

# ──────────────────────────────────────────────────────────────────────────
# Helper
# ──────────────────────────────────────────────────────────────────────────

defmodule Demo.K8s.Deploy do
  def create!(resource, params) do
    resource
    |> Ash.Changeset.for_create(:create, params, domain: Demo.K8s)
    |> Ash.create!(domain: Demo.K8s)
  end

  def list!(resource) do
    Ash.read!(resource, domain: Demo.K8s)
  end
end

# ──────────────────────────────────────────────────────────────────────────
# 1. Set up the K8s client
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Connecting to k3d cluster (context: k3d-ash-k8s-demo)...")

{:ok, config} = AshK8s.Client.Config.from_context("k3d-ash-k8s-demo")
client = AshK8s.Client.new(config)
Application.put_env(:ash_k8s, :client, client)

IO.puts("    Server   : #{config.host}")
IO.puts("    Namespace: #{config.namespace}")

# ──────────────────────────────────────────────────────────────────────────
# 2. Deploy Deployment
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Creating nginx Deployment...")

deployment = Demo.K8s.Deploy.create!(Demo.K8s.Deployment, %{
  name:      "nginx",
  namespace: "default",
  labels:    %{"app" => "nginx", "managed-by" => "ash-k8s"},
  spec: %{
    "replicas" => 1,
    "selector" => %{"matchLabels" => %{"app" => "nginx"}},
    "template" => %{
      "metadata" => %{"labels" => %{"app" => "nginx"}},
      "spec" => %{
        "containers" => [%{
          "name"  => "nginx",
          "image" => "nginx:alpine",
          "ports" => [%{"containerPort" => 80}]
        }]
      }
    }
  }
})

IO.puts("    Created Deployment/#{deployment.name}  uid=#{deployment.uid}")

# ──────────────────────────────────────────────────────────────────────────
# 3. Deploy Service
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Creating nginx Service...")

service = Demo.K8s.Deploy.create!(Demo.K8s.Service, %{
  name:      "nginx",
  namespace: "default",
  labels:    %{"app" => "nginx", "managed-by" => "ash-k8s"},
  spec: %{
    "selector" => %{"app" => "nginx"},
    "ports"    => [%{"port" => 80, "targetPort" => 80, "protocol" => "TCP"}],
    "type"     => "ClusterIP"
  }
})

IO.puts("    Created Service/#{service.name}  uid=#{service.uid}")

# ──────────────────────────────────────────────────────────────────────────
# 4. Deploy Ingress
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Creating nginx Ingress...")

ingress = Demo.K8s.Deploy.create!(Demo.K8s.Ingress, %{
  name:      "nginx",
  namespace: "default",
  labels:    %{"managed-by" => "ash-k8s"},
  spec: %{
    "rules" => [%{
      "http" => %{
        "paths" => [%{
          "path"     => "/",
          "pathType" => "Prefix",
          "backend"  => %{
            "service" => %{
              "name" => "nginx",
              "port" => %{"number" => 80}
            }
          }
        }]
      }
    }]
  }
})

IO.puts("    Created Ingress/#{ingress.name}  uid=#{ingress.uid}")

# ──────────────────────────────────────────────────────────────────────────
# 5. Wait for nginx pod to become Ready
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Waiting for nginx to become Ready...")

ready =
  Enum.reduce_while(1..30, false, fn attempt, _ ->
    Process.sleep(3_000)

    deps = Demo.K8s.Deploy.list!(Demo.K8s.Deployment)
    dep  = Enum.find(deps, &(&1.name == "nginx"))
    ready_replicas = get_in(dep, [Access.key(:status), "readyReplicas"]) || 0

    IO.write("    [#{attempt}/30] readyReplicas=#{ready_replicas} ")

    if ready_replicas >= 1 do
      IO.puts("[Ready!]")
      {:halt, true}
    else
      IO.puts("[waiting...]")
      {:cont, false}
    end
  end)

unless ready, do: raise("Timed out waiting for nginx")

# ──────────────────────────────────────────────────────────────────────────
# 6. Read back all resources via Ash
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Resources in cluster (read via Ash):")
IO.puts("    Deployments : #{Demo.K8s.Deploy.list!(Demo.K8s.Deployment) |> Enum.map(& &1.name) |> Enum.join(", ")}")
IO.puts("    Services    : #{Demo.K8s.Deploy.list!(Demo.K8s.Service) |> Enum.map(& &1.name) |> Enum.join(", ")}")
IO.puts("    Ingresses   : #{Demo.K8s.Deploy.list!(Demo.K8s.Ingress) |> Enum.map(& &1.name) |> Enum.join(", ")}")

# ──────────────────────────────────────────────────────────────────────────
# 7. Curl nginx through the k3d load-balancer
# ──────────────────────────────────────────────────────────────────────────

IO.puts("\n==> Curling http://localhost:9080/ ...")
Process.sleep(1_000)

{body, _} = System.cmd("curl", ["-s", "--max-time", "10", "http://localhost:9080/"], stderr_to_stdout: true)
{status_code, _} = System.cmd("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", "http://localhost:9080/"], stderr_to_stdout: true)

IO.puts("    HTTP status : #{status_code}")

if String.contains?(body, "nginx") or String.starts_with?(status_code, "2") do
  IO.puts("    Response    : #{String.slice(body, 0, 120) |> String.replace("\n", " ")}")
  IO.puts("""

  ╔══════════════════════════════════════════════════════════╗
  ║  SUCCESS — nginx is live via ash_k8s on                 ║
  ║            http://localhost:9080/                        ║
  ╚══════════════════════════════════════════════════════════╝
  """)
else
  IO.puts("    Body snippet: #{String.slice(body, 0, 200)}")
  IO.puts("\n  Could not confirm nginx response. HTTP #{status_code}")
end
