require "kubernetes"
require "json"

struct JSONPatch
  include Kubernetes::Serializable

  field op : Operation
  field path : String
  field value : JSON::Any

  def self.new(*, op : Operation, path, value : JSON::Any::Type)
    new op: op, path: path, value: JSON::Any.new(value)
  end

  def initialize(*, @op, @path, @value)
  end

  enum Operation
    ADD
    REMOVE
    REPLACE
    COPY
    MOVE
    TEST
  end
end
