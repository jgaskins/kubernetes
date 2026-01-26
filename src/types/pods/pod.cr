require "./container"

module Kubernetes
  struct Pod
    include Serializable

    field metadata : Metadata
    field spec : Spec
    field status : JSON::Any

    struct Spec
      include Serializable

      field volumes : Array(Volume) { [] of Volume }
      field containers : Array(Container)
      field restart_policy : String?
      field termination_grace_period_seconds : Int32
      field dns_policy : String
      field service_account_name : String?
      field service_account : String?
      field node_name : String = ""
      field security_context : JSON::Any
      field scheduler_name : String
      field tolerations : Array(Toleration)

      struct Toleration
        include Serializable

        field key : String = ""
        field operator : String = ""
        field effect : String = ""
        field toleration_seconds : Int32 = 0
      end

      struct Volume
        include Serializable

        field name : String
        field projected : Template?

        struct Template
          include Serializable

          field sources : Array(JSON::Any)
          field default_mode : Int32
        end
      end
    end

    struct Metadata
      include Serializable

      field namespace : String
      field name : String
      field generate_name : String?
      field uid : UUID
      field resource_version : String
      field creation_timestamp : Time
      field labels : Hash(String, String) = {} of String => String
      field annotations : Hash(String, String) = {} of String => String
      field owner_references : Array(OwnerReference) = [] of OwnerReference

      struct OwnerReference
        include Serializable
        field api_version : String = "apps/v1"
        field name : String
        field kind : String
        field uid : UUID
        field controller : Bool
        field block_owner_deletion : Bool?
      end
    end
  end

  define_resource "pods",
    group: "",
    type: Pod,
    prefix: "api"
end
