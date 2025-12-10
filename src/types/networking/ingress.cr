module Kubernetes
  module Networking
    struct Ingress
      include Serializable

      field ingress_class_name : String?
      field rules : Array(Rule) { [] of Rule }
      field tls : Array(TLS) { [] of TLS }

      struct Rule
        include Serializable

        field host : String
        field http : HTTP

        struct HTTP
          include Serializable

          field paths : Array(Path)

          struct Path
            include Serializable

            field path : String
            field path_type : PathType
            field backend : Backend

            enum PathType
              ImplementationSpecific
              Exact
              Prefix

              def to_json(json : ::JSON::Builder) : Nil
                to_s.to_json(json)
              end

              def to_yaml(yaml : YAML::Nodes::Builder) : Nil
                to_s.to_yaml(yaml)
              end
            end
          end
        end
      end

      struct TLS
        include Serializable
        field hosts : Array(String)
        field secret_name : String
      end

      struct Backend
        include Serializable

        getter service : Service

        struct Service
          include Serializable

          field name : String
          field port : Port

          struct Port
            include Serializable

            field number : Int32
          end
        end
      end
    end
  end

  define_resource "ingresses",
    singular_name: "ingress",
    group: "networking.k8s.io",
    type: Resource(Networking::Ingress),
    kind: "Ingress"
end
