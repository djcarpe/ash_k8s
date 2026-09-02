defmodule AshK8sTest do
  use ExUnit.Case, async: true

  alias AshK8s.Test.Widget

  describe "AshK8s.Resource.Info" do
    test "returns k8s metadata from the resource" do
      assert AshK8s.Resource.Info.group!(Widget) == "widgets.example.com"
      assert AshK8s.Resource.Info.version!(Widget) == "v1"
      assert AshK8s.Resource.Info.kind!(Widget) == "Widget"
      assert AshK8s.Resource.Info.plural!(Widget) == "widgets"
      assert AshK8s.Resource.Info.singular!(Widget) == "widget"
      assert AshK8s.Resource.Info.scope!(Widget) == :namespaced
      assert AshK8s.Resource.Info.short_names!(Widget) == ["w", "wg"]
      assert AshK8s.Resource.Info.categories!(Widget) == ["all"]
    end

    test "builds correct API paths" do
      assert AshK8s.Resource.Info.api_version!(Widget) == "widgets.example.com/v1"
      assert AshK8s.Resource.Info.api_path!(Widget) == "/apis/widgets.example.com/v1/widgets"

      assert AshK8s.Resource.Info.namespaced_api_path!(Widget, "my-ns") ==
               "/apis/widgets.example.com/v1/namespaces/my-ns/widgets"
    end

    test "returns printer columns" do
      columns = AshK8s.Resource.Info.printer_columns!(Widget)
      assert length(columns) == 3
      names = Enum.map(columns, & &1.name)
      assert "PHASE" in names
      assert "REPLICAS" in names
      assert "AGE" in names
    end

    test "returns status config" do
      assert AshK8s.Resource.Info.status_enabled?(Widget) == true
      conditions = AshK8s.Resource.Info.status_conditions!(Widget)
      types = Enum.map(conditions, & &1.type)
      assert "Ready" in types
      assert "Degraded" in types
    end
  end

  describe "AshK8s.CRD" do
    test "generates a valid CRD structure" do
      crd = AshK8s.CRD.generate(Widget)

      assert crd["apiVersion"] == "apiextensions.k8s.io/v1"
      assert crd["kind"] == "CustomResourceDefinition"
      assert crd["metadata"]["name"] == "widgets.widgets.example.com"
      assert crd["spec"]["group"] == "widgets.example.com"
      assert crd["spec"]["scope"] == "Namespaced"

      names = crd["spec"]["names"]
      assert names["kind"] == "Widget"
      assert names["plural"] == "widgets"
      assert names["singular"] == "widget"
      assert names["shortNames"] == ["w", "wg"]
      assert names["categories"] == ["all"]
    end

    test "includes printer columns in CRD" do
      crd = AshK8s.CRD.generate(Widget)
      version = hd(crd["spec"]["versions"])
      columns = version["additionalPrinterColumns"]

      assert length(columns) == 3
      phase_col = Enum.find(columns, &(&1["name"] == "PHASE"))
      assert phase_col["jsonPath"] == ".status.phase"
      assert phase_col["type"] == "string"
    end

    test "includes status subresource when enabled" do
      crd = AshK8s.CRD.generate(Widget)
      version = hd(crd["spec"]["versions"])
      assert version["subresources"] == %{"status" => %{}}
    end

    test "to_yaml produces a YAML string" do
      yaml = AshK8s.CRD.generate_yaml(Widget)
      assert is_binary(yaml)
      assert String.contains?(yaml, "CustomResourceDefinition")
      assert String.contains?(yaml, "widgets.example.com")
    end
  end

  describe "AshK8s.Operator.Info" do
    alias AshK8s.Test.WidgetDomain

    test "returns operator configuration" do
      assert AshK8s.Operator.Info.name!(WidgetDomain) == "widget-operator"
      assert AshK8s.Operator.Info.namespace!(WidgetDomain) == "default"
      assert AshK8s.Operator.Info.leader_election?(WidgetDomain) == false
    end

    test "returns watches" do
      watches = AshK8s.Operator.Info.watches!(WidgetDomain)
      assert length(watches) == 1
      watch = hd(watches)
      assert watch.resource == AshK8s.Test.Widget
      assert watch.controller == AshK8s.Test.WidgetController
    end

    test "find watch by resource" do
      watch = AshK8s.Operator.Info.watch_for_resource(WidgetDomain, AshK8s.Test.Widget)
      assert watch != nil
      assert watch.controller == AshK8s.Test.WidgetController
    end
  end

  describe "AshK8s.Controller" do
    test "controller module exposes its resource" do
      assert AshK8s.Test.WidgetController.__ash_k8s_resource__() == AshK8s.Test.Widget
    end

    test "controller has no default finalize/3 (finalizers are opt-in)" do
      refute function_exported?(AshK8s.Test.WidgetController, :finalize, 3)
    end

    test "resources get primary read/create/update/destroy actions" do
      for type <- [:read, :create, :update, :destroy] do
        action = Ash.Resource.Info.primary_action(Widget, type)
        assert action, "no primary #{type} action injected"
      end
    end
  end

  describe "AshK8s.Client.Config" do
    test "in_cluster? returns false outside a pod" do
      refute AshK8s.Client.Config.in_cluster?()
    end

    test "from_file returns error for nonexistent path" do
      assert {:error, _} = AshK8s.Client.Config.from_file("/nonexistent/kubeconfig")
    end

    test "reloads a bearer token file for every request" do
      token_path =
        Path.join(System.tmp_dir!(), "ash-k8s-token-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(token_path) end)
      File.write!(token_path, "token-a")
      test_pid = self()

      adapter = fn request ->
        send(test_pid, {:authorization, Req.Request.get_header(request, "authorization")})

        {request,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: "{}"
         )}
      end

      config = %AshK8s.Client.Config{
        host: "https://k8s.test",
        auth: {:bearer_file, token_path}
      }

      client = AshK8s.Client.new(config)
      client = %{client | req: Req.merge(client.req, adapter: adapter)}

      assert {:ok, %{}} = AshK8s.Client.get(client, "/api/v1/namespaces")
      assert_receive {:authorization, ["Bearer token-a"]}

      File.write!(token_path, "token-b")

      assert {:ok, %{}} = AshK8s.Client.get(client, "/api/v1/namespaces")
      assert_receive {:authorization, ["Bearer token-b"]}

      File.write!(token_path, " \n")

      assert {:error, %RuntimeError{message: empty_message}} =
               AshK8s.Client.get(client, "/api/v1/namespaces")

      assert empty_message =~ "Kubernetes bearer token file is empty"
      File.rm!(token_path)

      assert {:error, %RuntimeError{message: missing_message}} =
               AshK8s.Client.get(client, "/api/v1/namespaces")

      assert missing_message =~ "Could not read Kubernetes bearer token file"
    end

    test "preserves static bearer token authentication" do
      request =
        Req.new()
        |> AshK8s.Client.Config.apply_auth({:bearer, "static-token"})

      assert Req.Request.get_header(request, "authorization") == ["Bearer static-token"]
    end
  end
end
