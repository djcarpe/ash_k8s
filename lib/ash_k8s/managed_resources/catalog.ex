defmodule AshK8s.ManagedResources.Catalog do
  @moduledoc false

  # All standard Kubernetes resource types with their API metadata.
  @entries [
    # Core group (group: "")
    %{
      name: :pod,
      group: "",
      version: "v1",
      kind: "Pod",
      plural: "pods",
      singular: "pod",
      scope: :namespaced
    },
    %{
      name: :service,
      group: "",
      version: "v1",
      kind: "Service",
      plural: "services",
      singular: "service",
      scope: :namespaced
    },
    %{
      name: :configmap,
      group: "",
      version: "v1",
      kind: "ConfigMap",
      plural: "configmaps",
      singular: "configmap",
      scope: :namespaced
    },
    %{
      name: :secret,
      group: "",
      version: "v1",
      kind: "Secret",
      plural: "secrets",
      singular: "secret",
      scope: :namespaced
    },
    %{
      name: :serviceaccount,
      group: "",
      version: "v1",
      kind: "ServiceAccount",
      plural: "serviceaccounts",
      singular: "serviceaccount",
      scope: :namespaced
    },
    %{
      name: :persistentvolumeclaim,
      group: "",
      version: "v1",
      kind: "PersistentVolumeClaim",
      plural: "persistentvolumeclaims",
      singular: "persistentvolumeclaim",
      scope: :namespaced
    },
    %{
      name: :persistentvolume,
      group: "",
      version: "v1",
      kind: "PersistentVolume",
      plural: "persistentvolumes",
      singular: "persistentvolume",
      scope: :cluster
    },
    %{
      name: :namespace,
      group: "",
      version: "v1",
      kind: "Namespace",
      plural: "namespaces",
      singular: "namespace",
      scope: :cluster
    },
    %{
      name: :node,
      group: "",
      version: "v1",
      kind: "Node",
      plural: "nodes",
      singular: "node",
      scope: :cluster
    },
    %{
      name: :resourcequota,
      group: "",
      version: "v1",
      kind: "ResourceQuota",
      plural: "resourcequotas",
      singular: "resourcequota",
      scope: :namespaced
    },
    %{
      name: :limitrange,
      group: "",
      version: "v1",
      kind: "LimitRange",
      plural: "limitranges",
      singular: "limitrange",
      scope: :namespaced
    },
    %{
      name: :endpoints,
      group: "",
      version: "v1",
      kind: "Endpoints",
      plural: "endpoints",
      singular: "endpoints",
      scope: :namespaced
    },
    # apps
    %{
      name: :deployment,
      group: "apps",
      version: "v1",
      kind: "Deployment",
      plural: "deployments",
      singular: "deployment",
      scope: :namespaced
    },
    %{
      name: :statefulset,
      group: "apps",
      version: "v1",
      kind: "StatefulSet",
      plural: "statefulsets",
      singular: "statefulset",
      scope: :namespaced
    },
    %{
      name: :daemonset,
      group: "apps",
      version: "v1",
      kind: "DaemonSet",
      plural: "daemonsets",
      singular: "daemonset",
      scope: :namespaced
    },
    %{
      name: :replicaset,
      group: "apps",
      version: "v1",
      kind: "ReplicaSet",
      plural: "replicasets",
      singular: "replicaset",
      scope: :namespaced
    },
    # batch
    %{
      name: :job,
      group: "batch",
      version: "v1",
      kind: "Job",
      plural: "jobs",
      singular: "job",
      scope: :namespaced
    },
    %{
      name: :cronjob,
      group: "batch",
      version: "v1",
      kind: "CronJob",
      plural: "cronjobs",
      singular: "cronjob",
      scope: :namespaced
    },
    # networking.k8s.io
    %{
      name: :ingress,
      group: "networking.k8s.io",
      version: "v1",
      kind: "Ingress",
      plural: "ingresses",
      singular: "ingress",
      scope: :namespaced
    },
    %{
      name: :networkpolicy,
      group: "networking.k8s.io",
      version: "v1",
      kind: "NetworkPolicy",
      plural: "networkpolicies",
      singular: "networkpolicy",
      scope: :namespaced
    },
    %{
      name: :ingressclass,
      group: "networking.k8s.io",
      version: "v1",
      kind: "IngressClass",
      plural: "ingressclasses",
      singular: "ingressclass",
      scope: :cluster
    },
    # rbac.authorization.k8s.io
    %{
      name: :role,
      group: "rbac.authorization.k8s.io",
      version: "v1",
      kind: "Role",
      plural: "roles",
      singular: "role",
      scope: :namespaced
    },
    %{
      name: :clusterrole,
      group: "rbac.authorization.k8s.io",
      version: "v1",
      kind: "ClusterRole",
      plural: "clusterroles",
      singular: "clusterrole",
      scope: :cluster
    },
    %{
      name: :rolebinding,
      group: "rbac.authorization.k8s.io",
      version: "v1",
      kind: "RoleBinding",
      plural: "rolebindings",
      singular: "rolebinding",
      scope: :namespaced
    },
    %{
      name: :clusterrolebinding,
      group: "rbac.authorization.k8s.io",
      version: "v1",
      kind: "ClusterRoleBinding",
      plural: "clusterrolebindings",
      singular: "clusterrolebinding",
      scope: :cluster
    },
    # autoscaling
    %{
      name: :horizontalpodautoscaler,
      group: "autoscaling",
      version: "v2",
      kind: "HorizontalPodAutoscaler",
      plural: "horizontalpodautoscalers",
      singular: "horizontalpodautoscaler",
      scope: :namespaced
    },
    # policy
    %{
      name: :poddisruptionbudget,
      group: "policy",
      version: "v1",
      kind: "PodDisruptionBudget",
      plural: "poddisruptionbudgets",
      singular: "poddisruptionbudget",
      scope: :namespaced
    },
    # storage.k8s.io
    %{
      name: :storageclass,
      group: "storage.k8s.io",
      version: "v1",
      kind: "StorageClass",
      plural: "storageclasses",
      singular: "storageclass",
      scope: :cluster
    }
  ]

  def all, do: @entries

  def get(name), do: Enum.find(@entries, &(&1.name == name))

  def fetch!(name) do
    case get(name) do
      nil -> raise ArgumentError, "unknown managed resource type: #{inspect(name)}"
      entry -> entry
    end
  end
end
