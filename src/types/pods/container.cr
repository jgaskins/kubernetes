module Kubernetes
  struct Container
    include Serializable

    field name : String
    field image : String
    field args : Array(String) = %w[]
    field ports : Array(Port) = [] of Port
    field env : Array(EnvVar) = [] of EnvVar
    field resources : Resources = Resources.new
    field termination_message_path : String?
    field termination_message_policy : String?
    field image_pull_policy : String

    struct Resources
      include Serializable

      field requests : Resource?
      field limits : Resource?

      def initialize
      end

      struct Resource
        include Serializable

        field cpu : String?
        field memory : String?
      end
    end

    struct EnvVar
      include Serializable

      field name : String
      field value : String { "" }
      field value_from : EnvVarSource?
    end

    struct EnvVarSource
      include Serializable

      field field_ref : ObjectFieldSelector?
      field config_map_key_ref : ConfigMapKeySelector?
      field resource_field_ref : ResourceFieldSelector?
      field secret_key_ref : SecretKeySelector?
    end

    struct ObjectFieldSelector
      include Serializable

      field api_version : String = "v1"
      field field_path : String
    end

    struct ConfigMapKeySelector
      include Serializable

      field key : String
      field name : String
      field optional : Bool?
    end

    struct ResourceFieldSelector
      include Serializable

      field container_name : String?
      field divisor : JSON::Any
      field resource : String
    end

    struct SecretKeySelector
      include Serializable

      field key : String
      field name : String
      field optional : Bool?
    end

    struct Port
      include Serializable

      field container_port : Int32?
      field protocol : String?
    end
  end
end
