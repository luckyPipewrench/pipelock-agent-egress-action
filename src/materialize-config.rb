#!/usr/bin/env ruby
# Materialize the Pipelock runtime config used by the action.
require "fileutils"
require "optparse"
require "yaml"

options = {}
OptionParser.new do |parser|
  parser.on("--input PATH") { |value| options[:input] = value }
  parser.on("--output PATH") { |value| options[:output] = value }
  parser.on("--agent-identity VALUE") { |value| options[:agent_identity] = value }
  parser.on("--listen VALUE") { |value| options[:listen] = value }
  parser.on("--evidence-dir PATH") { |value| options[:evidence_dir] = value }
  parser.on("--signing-key-path PATH") { |value| options[:signing_key_path] = value }
end.parse!

%i[output agent_identity listen evidence_dir signing_key_path].each do |key|
  abort("#{key.to_s.tr("_", "-")} is required") if options[key].to_s.empty?
end

def stringify_keys(value)
  case value
  when Hash
    value.each_with_object({}) do |(key, inner), out|
      out[key.to_s] = stringify_keys(inner)
    end
  when Array
    value.map { |inner| stringify_keys(inner) }
  else
    value
  end
end

def ensure_hash(parent, key)
  current = parent[key]
  unless current.nil? || current.is_a?(Hash)
    abort("#{key} must be a mapping when provided")
  end
  parent[key] = current || {}
end

config = {}
input = options[:input].to_s
if !input.empty? && File.exist?(input)
  raw = File.read(input)
  docs = YAML.parse_stream(raw).children
  abort("config must contain exactly one YAML document") if docs.length > 1
  config = YAML.safe_load(raw, permitted_classes: [], aliases: true) || {}
  abort("config root must be a mapping") unless config.is_a?(Hash)
  config = stringify_keys(config)
end

config["version"] ||= 1
config["mode"] ||= "balanced"
config["default_agent_identity"] = options[:agent_identity]
config["bind_default_agent_identity"] = true

fetch_proxy = ensure_hash(config, "fetch_proxy")
fetch_proxy["listen"] = options[:listen]

forward_proxy = ensure_hash(config, "forward_proxy")
forward_proxy["enabled"] = true

websocket_proxy = ensure_hash(config, "websocket_proxy")
websocket_proxy["enabled"] = true

flight_recorder = ensure_hash(config, "flight_recorder")
flight_recorder["enabled"] = true
flight_recorder["dir"] = options[:evidence_dir]
flight_recorder["redact"] = true
flight_recorder["sign_checkpoints"] = true
flight_recorder["signing_key_path"] = options[:signing_key_path]

FileUtils.mkdir_p(File.dirname(options[:output]))
File.write(options[:output], YAML.dump(config))
File.chmod(0o600, options[:output])
