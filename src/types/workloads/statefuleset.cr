module Kubernetes
  struct StatefulSet
    include Serializable

    field replicas : Int32
    field template : JSON::Any
    field selector : JSON::Any
    field volume_claim_templates : JSON::Any
  end

  define_resource "statefulsets",
    group: "apps",
    type: Resource(StatefulSet),
    kind: "StatefulSet"
end
