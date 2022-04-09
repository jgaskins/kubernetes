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
                field items : Spec?
                field properties : Properties = Properties.new
                field nullable : Bool = false
                field required : Array(String) = %w[]

                def to_crystal(name : String)
                  if nullable
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
                    "String"
                  when "boolean"
                    "Bool"
                  when "array"
                    if items = self.items
                      "Array(#{items.to_crystal(name)})"
                    else
                      raise "Array type specification for #{name.inspect} must contain an `items` key"
                    end
                  when "object"
                    name.camelcase
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
                        if spec.type == "object"
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
