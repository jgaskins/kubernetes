require "json"
require "yaml"

module Kubernetes
  module Serializable
    macro included
      include JSON::Serializable
      include YAML::Serializable
    end

    macro field(type)
      add_field {{type}}, getter
    end

    macro field?(type)
      add_field {{type}}, getter?
    end

    macro add_field(type, getter_type)
      @[JSON::Field(key: {{type.var.camelcase(lower: true)}})]
      @[YAML::Field(key: {{type.var.camelcase(lower: true)}})]
      {{getter_type}} {{type}}
    end
  end
end
