require "json"
require "yaml"

module Kubernetes
  module Serializable
    macro included
      include JSON::Serializable
      include YAML::Serializable
    end

    macro field(type)
      @[JSON::Field(key: {{type.var.camelcase(lower: true)}})]
      @[YAML::Field(key: {{type.var.camelcase(lower: true)}})]
      getter {{type}}
    end
  end
end
