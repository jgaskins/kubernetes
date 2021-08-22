require "yaml"
require "uuid/yaml"
require "./serializable"

require "./crd"

begin
  crd = Kubernetes::CRD.from_yaml(File.read(ARGV[0]))

  version = crd.spec.versions.find { |v| v.storage }.not_nil!
  properties = version.schema.open_api_v3_schema.properties.spec.properties

  code = <<-CRYSTAL
  struct #{crd.spec.names.kind}
    include Kubernetes::Serializable

    #{properties.to_crystal}
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

  puts code
rescue ex
  STDERR.puts ex
  STDERR.puts ex.pretty_inspect
  exit 1
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
