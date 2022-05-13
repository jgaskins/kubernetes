require "json"
require "yaml"

module Kubernetes
  module Serializable
    macro included
      include JSON::Serializable
      include YAML::Serializable
    end

    macro field(type, key = nil, &block)
      add_field {{type}}, getter, key: {{key}} {{block}}
    end

    macro field?(type, key = nil, &block)
      add_field {{type}}, getter?, key: {{key}} {{block}}
    end

    macro add_field(type, getter_type, key = nil, &block)
      @[JSON::Field(key: {{key || type.var.camelcase(lower: true)}})]
      @[YAML::Field(key: {{key || type.var.camelcase(lower: true)}})]
      {{getter_type}} {{type}} {{block}}
    end
  end
end
