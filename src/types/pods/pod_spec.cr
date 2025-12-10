module Kubernetes
  struct PodTemplate
    include Serializable

    field metadata : Metadata?
    field spec : PodSpec?
  end

  # https://github.com/kubernetes/kubernetes/blob/2dede1d4d453413da6fd852e00fc7d4c8784d2a8/staging/src/k8s.io/client-go/applyconfigurations/core/v1/podspec.go#L27-L63
  struct PodSpec
    include Serializable

    field containers : Array(Container)
    field restart_policy : String?
    field termination_grace_period_seconds : Int32
    field dns_policy : String
    field service_account_name : String?
    field service_account : String?
    field security_context : JSON::Any
    field scheduler_name : String
  end
end
