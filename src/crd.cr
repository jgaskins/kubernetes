require "./serializable"

module Kubernetes
  struct CRD
    include Serializable

    field api_version : String
    field kind : String
    # field metadata : Metadata
    field spec : Spec

    struct Spec
      include Serializable

      field group : String
      field versions : Array(Version)
      field scope : String
      field names : Names

      struct Names
        include Serializable

        field plural : String
        field singular : String
        field kind : String
        field short_names : Array(String)
      end

      struct Version
        include Serializable

        field name : String
        field served : Bool = false
        field storage : Bool = false
        field schema : Schema

        struct Schema
          include Serializable

          field open_api_v3_schema : OpenAPIV3Schema, key: "openAPIV3Schema"

          struct OpenAPIV3Schema
            include Serializable

            field type : String
            field properties : Properties

            struct Properties
              include Serializable
              field spec : Spec

              class Spec
                include Serializable

                field type : String
                field default : YAML::Any?
                field items : Spec?
                field properties : Properties { Properties.new }
                field? nullable : Bool = false
                field enum : Array(String)?
                field required : Array(String) { %w[] }
                field? preserve_unknown_fields : Bool = false, key: "x-kubernetes-preserve-unknown-fields"

                def to_crystal(name : String)
                  if nullable?
                    "#{crystal_type(name)}?"
                  else
                    crystal_type(name)
                  end
                end

                private def crystal_type(name : String)
                  case type
                  when "integer"
                    "Int64"
                  when "string"
                    if e = self.enum
                      name.camelcase
                    else
                      "String"
                    end
                  when "boolean"
                    "Bool"
                  when "array"
                    if items = self.items
                      type_name = "Array(#{items.to_crystal(name)})"
                      # Go doesn't emit empty arrays :-(
                      if default_value = default
                        if default_array = default_value.as_a?
                          if default_array.empty?
                            type_name = "#{type_name} { [] of #{items.to_crystal(name)} }"
                          end
                        else
                          raise "Default value for an array must be an array. Got: #{default_value.inspect}"
                        end
                      end

                      type_name
                    else
                      raise "Array type specification for #{name.inspect} must contain an `items` key"
                    end
                  when "object"
                    if preserve_unknown_fields?
                      "Hash(String, JSON::Any)"
                    else
                      name.camelcase
                    end
                  else
                    raise "Unknown type: #{type.inspect}"
                  end
                end

                struct Properties
                  include Enumerable({String, Spec})

                  alias Mapping = Hash(String, Spec)

                  @mapping : Mapping = Mapping.new

                  def initialize
                  end

                  def initialize(json : JSON::PullParser)
                    @mapping = Mapping.new(json)
                  end

                  def initialize(ctx : YAML::ParseContext, value : YAML::Nodes::Node)
                    @mapping = Mapping.new(ctx, value)
                  end

                  def each
                    @mapping.each { |value| yield value }
                  end

                  def [](key : String)
                    @mapping[key]
                  end

                  def to_json(json : JSON::Builder)
                    @mapping.to_json json
                  end

                  def to_crystal
                    String.build do |str|
                      @mapping.each do |name, spec|
                        str << "  @[YAML::Field(key: #{name.inspect})]\n"
                        str << "  @[JSON::Field(key: #{name.inspect})]\n"
                        str << "  getter #{name.underscore} : #{spec.to_crystal(name)}\n"
                        if spec.type == "object" && !spec.preserve_unknown_fields?
                          str << <<-CRYSTAL
                            struct #{name.camelcase}
                              include ::Kubernetes::Serializable

                              #{spec.properties.to_crystal}
                            end

                          CRYSTAL
                        elsif spec.type == "array" && (items = spec.items) && items.type == "object"
                          str << <<-CRYSTAL
                            struct #{name.camelcase}
                              include ::Kubernetes::Serializable

                              #{items.properties.to_crystal}
                            end

                          CRYSTAL
                        elsif spec.type == "string" && (e = spec.enum)
                          str.puts "enum #{name.camelcase}"
                          e.each do |item|
                            str.puts item.camelcase
                          end
                          str.puts "end"
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
