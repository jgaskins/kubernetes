require "base64"

module Base64Converter(T)
  extend self

  def from_json(json : JSON::PullParser)
    T.from_json Base64.decode_string(json.read_string)
  end

  def to_json(value : T, json : JSON::Builder)
    Base64.strict_encode(value.to_json).to_json json
  end
end
