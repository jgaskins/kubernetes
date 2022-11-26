require "json"
require "yaml"

module Kubernetes
  module Serializable
    macro included
      include JSON::Serializable
      include YAML::Serializable
    end

    macro field(type, key = nil, **args, &block)
      add_field {{type}}, getter, key: {{key}} {% unless args.empty? %}{% for k,v in args %}, {{k}}: {{v}}{% end %}{% end %} {{block}}
    end

    macro field?(type, key = nil, **args, &block)
      add_field {{type}}, getter?, key: {{key}} {% unless args.empty? %}{% for k,v in args %}, {{k}}: {{v}}{% end %}{% end %} {{block}}
    end

    macro add_field(type, getter_type, key = nil, **args, &block)
      @[JSON::Field(key: {{key || type.var.camelcase(lower: true)}}{% unless args.empty? %}{% for k,v in args %}, {{k}}: {{v}}{% end %}{% end %})]
      @[YAML::Field(key: {{key || type.var.camelcase(lower: true)}}{% unless args.empty? %}{% for k,v in args %}, {{k}}: {{v}}{% end %}{% end %})]
      {{getter_type}} {{type}} {{block}}
      {% if flag? :debug_k8s_add_field %}
        {% debug %}
      {% end %}
    end
  end
end
