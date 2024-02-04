require "json"
require "yaml"

module Kubernetes
  module Serializable
    macro included
      include JSON::Serializable
      include YAML::Serializable
    end

    macro field(type, key = nil, **args, &block)
      add_field {{type}}, getter, key: {{key}} {% unless args.empty? %}{% for k, v in args %}, {{k}}: {{v}}{% end %}{% end %} {{block}}
    end

    macro field?(type, key = nil, **args, &block)
      add_field {{type}}, getter?, key: {{key}} {% unless args.empty? %}{% for k, v in args %}, {{k}}: {{v}}{% end %}{% end %} {{block}}
    end

    macro field!(type, key = nil, **args, &block)
      add_field {{type}}, getter!, key: {{key}} {% unless args.empty? %}{% for k, v in args %}, {{k}}: {{v}}{% end %}{% end %} {{block}}
    end

    macro add_field(type, getter_type, key = nil, **args, &block)
      @[JSON::Field(key: "{{(key || type.var.camelcase(lower: true)).id}}"{% unless args.empty? %}{% for k, v in args %}, {{k}}: {{v}}{% end %}{% end %})]
      @[YAML::Field(key: "{{(key || type.var.camelcase(lower: true)).id}}"{% unless args.empty? %}{% for k, v in args %}, {{k}}: {{v}}{% end %}{% end %})]
      {{getter_type}} {{type}} {{block}}
      {% if flag? :debug_k8s_add_field %}
        {% debug %}
      {% end %}
    end

    def pretty_print(pp) : Nil
      prefix = "#{{{@type.name.id.stringify}}}("
      pp.surround(prefix, ")", left_break: "", right_break: nil) do
        count = 0
        {% for ivar, i in @type.instance_vars.map(&.name) %}
          if @{{ivar}}
            if (count += 1) > 1
              pp.comma
            end
            pp.group do
              pp.text "@{{ivar.id}}="
              pp.nest do
                pp.breakable ""
                @{{ivar.id}}.pretty_print(pp)
              end
            end
          end
        {% end %}
      end
    end
  end
end
