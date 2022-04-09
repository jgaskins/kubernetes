require "json"
require "yaml"

module Kubernetes
  module Serializable
    macro included
      include JSON::Serializable
      include YAML::Serializable
    end

    macro field(type, key = nil)
      add_field {{type}}, getter, key: {{key}}
    end

    macro field?(type, key = nil)
      add_field {{type}}, getter?, key: {{key}}
    end

    macro add_field(type, getter_type, key = nil)
      @[JSON::Field(key: {{key || type.var.camelcase(lower: true)}})]
      @[YAML::Field(key: {{key || type.var.camelcase(lower: true)}})]
      {{getter_type}} {{type}}
    end
  end
end
