require "./spec_helper"

require "../src/kubernetes"

# Defines a NATSCluster, a NATSStream, and a NATSConsumer
Kubernetes.import_crd "spec/fixtures/nats.yaml"

describe "import_crd" do
  it "defines the constants" do
    NATSCluster.should_not eq nil
    NATSStream.should_not eq nil
    NATSConsumer.should_not eq nil
  end
end
