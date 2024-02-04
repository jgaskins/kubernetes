require "yaml"
require "uuid/yaml"
require "./serializable"

require "./crd"

begin
  File.read(ARGV[0]).split(/\n---\n/).each do |yaml|
    crd = Kubernetes::CRD.from_yaml(yaml)

    version = crd.spec.versions.find { |v| v.storage }.not_nil!
    spec = version.schema.open_api_v3_schema.properties.spec
    properties = spec.properties

    code = <<-CRYSTAL
    struct #{crd.spec.names.kind}
      include Kubernetes::Serializable

      #{properties.to_crystal}

      #{spec.initializer}
    end

    Kubernetes.define_resource(
      name: #{crd.spec.names.plural.inspect},
      group: #{crd.spec.group.inspect},
      type: Kubernetes::Resource(#{crd.spec.names.kind}),
      kind: "#{crd.spec.names.kind}",
      version: #{version.name.inspect},
      prefix: "apis",
      singular_name: #{crd.spec.names.singular.inspect},
    )
    CRYSTAL

    puts code
  end
rescue ex
  STDERR.puts ex
  STDERR.puts ex.pretty_inspect
  exit 1
end
