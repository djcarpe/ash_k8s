defmodule AshK8s.DataLayerSSACreateTest do
  @moduledoc """
  The data layer's create must be a server-side apply (idempotent create-or-update),
  not a plain POST — otherwise an operator reconcile that calls `Ash.create` a second
  time on an existing object gets a 409 Conflict.
  """
  use ExUnit.Case, async: false

  alias AshK8s.Test.Widget

  # Custom Req adapter that captures the outgoing request and returns a canned
  # created object. Avoids a Plug/Req.Test dependency.
  defp capturing_adapter(test_pid) do
    fn request ->
      send(test_pid, %{
        method: request.method,
        path: request.url.path,
        query: URI.decode_query(request.url.query || ""),
        content_type: Req.Request.get_header(request, "content-type"),
        body: Jason.decode!(request.body)
      })

      response =
        Req.Response.new(
          status: 200,
          headers: [{"content-type", "application/json"}],
          body:
            Jason.encode!(%{
              "apiVersion" => "widgets.example.com/v1",
              "kind" => "Widget",
              "metadata" => %{"name" => "w1", "namespace" => "default", "uid" => "abc"},
              "spec" => %{"replicas" => 2}
            })
        )

      {request, response}
    end
  end

  setup do
    test_pid = self()

    req =
      Req.new(
        base_url: "https://k8s.test",
        decode_body: false,
        adapter: capturing_adapter(test_pid)
      )

    client = %AshK8s.Client{config: %AshK8s.Client.Config{namespace: "default"}, req: req}

    Application.put_env(:ash_k8s, :client, client)
    on_exit(fn -> Application.delete_env(:ash_k8s, :client) end)

    :ok
  end

  test "create issues a server-side apply (PATCH) to the named object path" do
    {:ok, record} =
      Widget
      |> Ash.Changeset.for_create(:create, %{
        name: "w1",
        namespace: "default",
        spec: %{"replicas" => 2}
      })
      |> Ash.create()

    assert record.name == "w1"
    assert record.spec == %{"replicas" => 2}

    assert_received %{} = req

    # Server-side apply is a PATCH with the apply-patch content type…
    assert req.method == :patch
    assert req.content_type == ["application/apply-patch+yaml"]

    # …to the NAMED object path (…/widgets/w1), not the collection path (…/widgets).
    assert req.path == "/apis/widgets.example.com/v1/namespaces/default/widgets/w1"

    # …carrying a fieldManager so the operator owns its fields.
    assert Map.has_key?(req.query, "fieldManager")

    # …with a well-formed manifest body.
    assert req.body["apiVersion"] == "widgets.example.com/v1"
    assert req.body["kind"] == "Widget"
    assert req.body["metadata"]["name"] == "w1"
    assert req.body["spec"] == %{"replicas" => 2}
  end

  test "owner references are carried into metadata.ownerReferences" do
    owner = %{
      "apiVersion" => "widgets.example.com/v1",
      "kind" => "Widget",
      "name" => "parent",
      "uid" => "parent-uid",
      "controller" => true,
      "blockOwnerDeletion" => true
    }

    {:ok, _record} =
      Widget
      |> Ash.Changeset.for_create(:create, %{
        name: "w1",
        namespace: "default",
        spec: %{},
        owner_references: [owner]
      })
      |> Ash.create()

    assert_received %{} = req
    assert req.body["metadata"]["ownerReferences"] == [owner]
  end

  test "data-bearing objects (ConfigMap/Secret) carry data/stringData/type, not spec" do
    {:ok, _record} =
      Widget
      |> Ash.Changeset.for_create(:create, %{
        name: "w1",
        namespace: "default",
        data: %{"config.toml" => "x = 1"},
        string_data: %{"password" => "hunter2"},
        type: "Opaque"
      })
      |> Ash.create()

    assert_received %{} = req
    assert req.body["data"] == %{"config.toml" => "x = 1"}
    assert req.body["stringData"] == %{"password" => "hunter2"}
    assert req.body["type"] == "Opaque"
    # No empty spec/status should be emitted for a data-bearing object — a
    # spec-less kind's schema (ConfigMap/Secret) rejects both under strict SSA.
    refute Map.has_key?(req.body, "spec")
    refute Map.has_key?(req.body, "status")
  end

  test "spec is included when non-empty (workload objects)" do
    {:ok, _record} =
      Widget
      |> Ash.Changeset.for_create(:create, %{
        name: "w1",
        namespace: "default",
        spec: %{"replicas" => 3}
      })
      |> Ash.create()

    assert_received %{} = req
    assert req.body["spec"] == %{"replicas" => 3}
  end

  test "the field manager is overridable via changeset context" do
    {:ok, _record} =
      Widget
      |> Ash.Changeset.for_create(:create, %{name: "w1", namespace: "default", spec: %{}})
      |> Ash.Changeset.set_context(%{field_manager: "mars-operator"})
      |> Ash.create()

    assert_received %{} = req
    assert req.query["fieldManager"] == "mars-operator"
  end
end
