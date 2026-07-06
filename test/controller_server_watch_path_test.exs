defmodule AshK8s.ControllerServerWatchPathTest do
  use ExUnit.Case, async: true

  alias AshK8s.Controller.Server

  test "cluster-wide watch when watch_namespace is :all" do
    assert Server.watch_path(AshK8s.Test.Widget, :all) ==
             "/apis/widgets.example.com/v1/widgets"
  end

  test "single-namespace watch when watch_namespace is a binary" do
    assert Server.watch_path(AshK8s.Test.Widget, "mars") ==
             "/apis/widgets.example.com/v1/namespaces/mars/widgets"
  end

  test "defaults to cluster-wide when watch_namespace is nil" do
    assert Server.watch_path(AshK8s.Test.Widget, nil) ==
             "/apis/widgets.example.com/v1/widgets"
  end
end
