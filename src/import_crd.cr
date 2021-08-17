require "yaml"
require "uuid/yaml"
require "./serializable"

begin
  crd = CRD.from_yaml(File.read(ARGV[0]))

  version = crd.spec.versions.find { |v| v.storage }.not_nil!
  properties = version.schema.open_api_v3_schema.properties.spec.properties

  puts <<-CRYSTAL
  struct #{crd.spec.names.kind}
    include Kubernetes::Serializable

  #{properties.map {|key, spec| "  field #{key.underscore} : #{type_for spec}\n" }.join}
  end

  Kubernetes.define_resource(
    name: #{crd.spec.names.plural.inspect},
    group: #{crd.spec.group.inspect},
    type: Kubernetes::Resource(#{crd.spec.names.kind}),
    version: #{version.name.inspect},
    prefix: "apis",
    singular_name: #{crd.spec.names.singular.inspect},
  )
  CRYSTAL
rescue ex
  STDERR.puts ex
  STDERR.puts ex.pretty_inspect
  exit 1
end

struct CRD
  include Kubernetes::Serializable

  field api_version : String
  field kind : String
  # field metadata : Kubernetes::Metadata
  field spec : Spec

  struct Spec
    include Kubernetes::Serializable

    field group : String
    field versions : Array(Version)
    field scope : String
    field names : Names

    struct Names
      include Kubernetes::Serializable

      field plural : String
      field singular : String
      field kind : String
      field short_names : Array(String)
    end

    struct Version
      include Kubernetes::Serializable

      field name : String
      field served : Bool = false
      field storage : Bool = false
      field schema : Schema

      struct Schema
        include Kubernetes::Serializable

        @[JSON::Field(key: "openAPIV3Schema")]
        @[YAML::Field(key: "openAPIV3Schema")]
        getter open_api_v3_schema : OpenAPIV3Schema

        struct OpenAPIV3Schema
          include Kubernetes::Serializable

          field type : String
          field properties : Properties

          struct Properties
            include Kubernetes::Serializable
            field spec : Spec

            struct Spec
              include Kubernetes::Serializable

              field type : String
              field properties : Hash(String, Hash(String, String | Hash(String, String | Int64)))
            end
          end
        end
      end
    end
  end
end

def type_for(spec)
  case spec["type"]
  when "string" then %{String = ""}
  when "integer" then %{Int64 = 0u64}
  when "array"
    case spec["items"].as(Hash)["type"]
    when "string" then "Array(String) = %w[]"
    when "integer" then "Array(Int64) = [] of Int64"
    else "Array(JSON::Any) = [] of JSON::Any"
    end
  else
    "JSON::Any = JSON::Any.new(nil)"
  end
end
