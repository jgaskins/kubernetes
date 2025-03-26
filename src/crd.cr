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
      field names : Names
      field scope : String
      field versions : Array(Version)

      struct Names
        include Serializable

        field plural : String
        field singular : String
        field kind : String
        field short_names : Array(String)?
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
            field description : String?
            field properties : Properties

            struct Properties
              include Serializable
              field spec : Spec

              class Spec
                include Serializable

                field type : String
                field description : String?
                field default : YAML::Any?
                field items : Spec?
                field properties : Properties { Properties.new }
                field? nullable : Bool = false
                field enum : Array(String)?
                field required : Array(String) { [] of String }
                field? preserve_unknown_fields : Bool = false, key: "x-kubernetes-preserve-unknown-fields"

                def initializer
                  String.build do |str|
                    str.puts "def initialize(*,"
                    properties.each do |name, property|
                      str << "  @" << name.underscore
                      if property.nullable?
                        str << " = nil"
                      elsif default = property.default
                        if default_array = default.as_a?
                          if (items = property.items) && default_array.empty?
                            str << " = " << property.crystal_type(name) << ".new"
                          else
                            str << " = " << default.inspect
                          end
                        elsif default_hash = default.as_h?
                          str << " = {} of String => JSON::Any"
                        else
                          str << " = " << default.inspect
                        end
                      end
                      str.puts ','
                    end
                    str.puts ')'
                    str.puts "end"
                  end
                end

                def to_crystal(name : String)
                  String.build do |str|
                    type_name = crystal_type(name)
                    if nullable?
                      type_name += "?"
                    end

                    str << type_name

                    if default_value = default
                      case type
                      # Go doesn't emit empty arrays, so a default empty array
                      # needs to be handled manually
                      when "array"
                        if default_array = default_value.as_a?
                          if default_array.empty?
                            if items = self.items
                              str << " = [] of #{items.to_crystal(name)}"
                            else
                              raise "Array type specification for #{name.inspect} must contain an `items` key"
                            end
                          end
                        else
                          raise "Default value for an array must be an array. Got: #{default_value.inspect}"
                        end
                      when "string"
                        if e = @enum
                          str << " = :" << default_value
                        else
                          str << " = "
                          default_value.inspect str
                        end
                      when "integer"
                        str << " = " << default_value
                      end
                    end
                  end
                end

                protected def crystal_type(name : String)
                  case type
                  when "integer"
                    "Int64"
                  when "string"
                    if e = @enum
                      name.camelcase
                    else
                      "String"
                    end
                  when "boolean"
                    "Bool"
                  when "array"
                    if items = self.items
                      "Array(#{items.to_crystal(name)})"
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
                        spec.description.try &.each_line do |line|
                          str.puts "  # #{line}"
                        end
                        str << "  @[YAML::Field(key: #{name.inspect})]\n"
                        str << "  @[JSON::Field(key: #{name.inspect})]\n"
                        str << "  getter #{name.underscore} : #{spec.to_crystal(name)}\n"
                        if spec.type == "object" && !spec.preserve_unknown_fields?
                          spec.description.try &.each_line do |line|
                            str.puts "  # #{line}"
                          end
                          str << <<-CRYSTAL
                            struct #{name.camelcase}
                              include ::Kubernetes::Serializable

                              #{spec.properties.to_crystal}

                              #{spec.initializer}
                            end

                          CRYSTAL
                        elsif spec.type == "boolean"
                          # Alias a predicate method ending in a question mark.
                          str << <<-CRYSTAL
                            def #{name.underscore}?
                              #{name.underscore}
                            end

                          CRYSTAL
                        elsif spec.type == "array" && (items = spec.items) && items.type == "object"
                          spec.description.try &.each_line do |line|
                            str.puts "  # #{line}"
                          end
                          str << <<-CRYSTAL
                            struct #{name.camelcase}
                              include ::Kubernetes::Serializable

                              #{items.properties.to_crystal}

                              #{items.initializer}
                            end

                          CRYSTAL
                        elsif spec.type == "string" && (e = spec.enum)
                          spec.description.try &.each_line do |line|
                            str.puts "  # #{line}"
                          end
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
