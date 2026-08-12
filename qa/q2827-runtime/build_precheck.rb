#!/usr/bin/env ruby
require "csv"
require "fileutils"
require "find"
require "json"
require "open3"
require "tmpdir"
require "yaml"

INPUT_FILES = [
  "README.md",
  "broken_policy.yaml",
  "existing_usage.json",
  "precheck_contract.json",
  "requests/01-r01-editor.yaml",
  "requests/02-r02-build.yaml",
  "requests/03-r03-cache.yaml",
  "requests/04-r04-oversized.yaml",
  "requests/05-r05-workers.yaml",
  "requests/06-r06-quota.yaml",
  "requests/07-r07-storage.yaml",
  "requests/08-r08-ratio.yaml",
  "requests/09-r09-tiny.yaml",
  "requests/10-r10-archive.yaml"
].freeze
POLICY_FILES = ["00-namespace.yaml", "10-limitrange.yaml", "20-resourcequota.yaml"].freeze
RESULT_FILES = [
  "final_usage.json",
  "kubectl_namespace_dry_run.yaml",
  "kubectl_quota_dry_run.yaml",
  "normalized_containers.csv",
  "precheck_summary.json",
  "quota_trajectory.csv",
  "request_precheck.csv"
].freeze
USAGE_KEYS = %w[
  pods requests_cpu_m requests_memory_mi limits_cpu_m limits_memory_mi
  persistentvolumeclaims requests_storage_gi
].freeze
CONTRACT_KEYS = %w[
  contract_id namespace request_id_annotation required_kubectl_minor
  container_defaults container_min container_max max_limit_request_ratio quota
  request_order exact_input_files exact_policy_files exact_result_files expected
].freeze

def fail!(message)
  raise ArgumentError, message
end

def inventory(root)
  fail!("not a plain directory: #{root}") unless File.directory?(root) && !File.symlink?(root)
  result = []
  Find.find(root) do |entry|
    next if entry == root
    fail!("symlink is not allowed: #{entry}") if File.symlink?(entry)
    result << entry.delete_prefix("#{root}/") if File.file?(entry)
  end
  result.sort
end

def yaml_object(path)
  value = YAML.safe_load(File.read(path, encoding: "UTF-8"), permitted_classes: [], permitted_symbols: [], aliases: false)
  fail!("YAML root must be a mapping: #{path}") unless value.is_a?(Hash)
  value
rescue Psych::Exception => error
  fail!("invalid YAML #{path}: #{error.message}")
end

def yaml_text(text, label)
  value = YAML.safe_load(text, permitted_classes: [], permitted_symbols: [], aliases: false)
  fail!("YAML root must be a mapping: #{label}") unless value.is_a?(Hash)
  value
rescue Psych::Exception => error
  fail!("invalid YAML #{label}: #{error.message}")
end

def cpu_m(value)
  text = value.to_s
  match = /\A([0-9]+)m\z/.match(text)
  return match[1].to_i if match
  return text.to_i * 1000 if text.match?(/\A[0-9]+\z/)
  fail!("unsupported CPU quantity: #{text}")
end

def memory_mi(value)
  text = value.to_s
  match = /\A([0-9]+)Mi\z/.match(text)
  return match[1].to_i if match
  match = /\A([0-9]+)Gi\z/.match(text)
  return match[1].to_i * 1024 if match
  fail!("unsupported memory quantity: #{text}")
end

def storage_gi(value)
  text = value.to_s
  match = /\A([0-9]+)Gi\z/.match(text)
  return match[1].to_i if match
  fail!("unsupported storage quantity: #{text}")
end

def integer_quantity(value, label)
  text = value.to_s
  fail!("unsupported integer quantity for #{label}: #{text}") unless text.match?(/\A[0-9]+\z/)
  text.to_i
end

def quota_units(quota)
  expected = ["limits.cpu", "limits.memory", "persistentvolumeclaims", "pods", "requests.cpu", "requests.memory", "requests.storage"].sort
  fail!("quota keys mismatch") unless quota.keys.sort == expected
  {
    "pods" => integer_quantity(quota["pods"], "pods"),
    "requests_cpu_m" => cpu_m(quota["requests.cpu"]),
    "requests_memory_mi" => memory_mi(quota["requests.memory"]),
    "limits_cpu_m" => cpu_m(quota["limits.cpu"]),
    "limits_memory_mi" => memory_mi(quota["limits.memory"]),
    "persistentvolumeclaims" => integer_quantity(quota["persistentvolumeclaims"], "persistentvolumeclaims"),
    "requests_storage_gi" => storage_gi(quota["requests.storage"])
  }
end

def limit_units(item)
  required = %w[default defaultRequest max maxLimitRequestRatio min type].sort
  fail!("LimitRange keys mismatch") unless item.keys.sort == required
  fail!("LimitRange type must be Container") unless item["type"] == "Container"
  %w[default defaultRequest min max].each do |field|
    fail!("#{field} keys mismatch") unless item[field].is_a?(Hash) && item[field].keys.sort == %w[cpu memory]
  end
  ratio = item["maxLimitRequestRatio"]
  fail!("ratio keys mismatch") unless ratio.is_a?(Hash) && ratio.keys.sort == %w[cpu memory]
  {
    "request_cpu_m" => cpu_m(item.dig("defaultRequest", "cpu")),
    "request_memory_mi" => memory_mi(item.dig("defaultRequest", "memory")),
    "limit_cpu_m" => cpu_m(item.dig("default", "cpu")),
    "limit_memory_mi" => memory_mi(item.dig("default", "memory")),
    "min_cpu_m" => cpu_m(item.dig("min", "cpu")),
    "min_memory_mi" => memory_mi(item.dig("min", "memory")),
    "max_cpu_m" => cpu_m(item.dig("max", "cpu")),
    "max_memory_mi" => memory_mi(item.dig("max", "memory")),
    "ratio_cpu" => Integer(ratio["cpu"]),
    "ratio_memory" => Integer(ratio["memory"])
  }
rescue ArgumentError, TypeError
  fail!("LimitRange ratio must be an integer")
end

def metadata!(object, kind, name, namespace)
  fail!("apiVersion mismatch for #{kind}") unless object["apiVersion"] == "v1"
  fail!("kind mismatch: expected #{kind}") unless object["kind"] == kind
  metadata = object["metadata"]
  fail!("metadata missing for #{kind}") unless metadata.is_a?(Hash)
  fail!("name mismatch for #{kind}") unless metadata["name"] == name
  if namespace.nil?
    fail!("Namespace object must not set metadata.namespace") if metadata.key?("namespace")
  else
    fail!("namespace mismatch for #{kind}") unless metadata["namespace"] == namespace
  end
end

def write_csv(path, headers, rows)
  CSV.open(path, "wb", write_headers: true, headers: headers, row_sep: "\n") do |csv|
    rows.each { |row| csv << headers.map { |header| row[header] } }
  end
end

def json_write(path, object)
  File.binwrite(path, JSON.pretty_generate(object) + "\n")
end

def kubectl!(binary, *arguments)
  environment = { "KUBECONFIG" => ENV.fetch("KUBECONFIG") }
  stdout, stderr, status = Open3.capture3(environment, binary, *arguments)
  fail!("kubectl failed: #{arguments.join(' ')}: #{stderr.strip}") unless status.success?
  stdout.gsub(/\r\n?/, "\n")
end

def run(input_root, policy_root, output_root)
  input_files = inventory(input_root)
  fail!("input boundary mismatch: #{input_files.inspect}") unless input_files == INPUT_FILES
  policy_files = inventory(policy_root)
  fail!("policy boundary mismatch: #{policy_files.inspect}") unless policy_files == POLICY_FILES
  fail!("output root must not be a symlink") if File.symlink?(output_root)
  if File.exist?(output_root)
    fail!("output root must be an empty directory") unless File.directory?(output_root) && Dir.children(output_root).empty?
  end

  contract = JSON.parse(File.read(File.join(input_root, "precheck_contract.json"), encoding: "UTF-8"))
  fail!("contract schema mismatch") unless contract.keys.sort == CONTRACT_KEYS.sort
  fail!("unsupported contract_id") unless contract["contract_id"] == "internet-sandbox-precheck-v3"
  fail!("input contract mismatch") unless contract["exact_input_files"] == INPUT_FILES
  fail!("policy/result contract mismatch") unless contract["exact_policy_files"] == POLICY_FILES && contract["exact_result_files"] == RESULT_FILES
  fail!("request order mismatch") unless contract["request_order"] == %w[R01 R02 R03 R04 R05 R06 R07 R08 R09 R10]
  fail!("kubectl minor contract mismatch") unless contract["required_kubectl_minor"] == "1.32"
  namespace = contract["namespace"]
  fail!("namespace contract mismatch") unless namespace == "internet-sandbox"

  broken = File.read(File.join(input_root, "broken_policy.yaml"), encoding: "UTF-8")
  fail!("broken starter policy is not recognizable") unless broken.include?('hard: {pods: "100"}') && broken.include?('default: {cpu: "1", memory: 2Gi}')

  namespace_policy = yaml_object(File.join(policy_root, "00-namespace.yaml"))
  limit_policy = yaml_object(File.join(policy_root, "10-limitrange.yaml"))
  quota_policy = yaml_object(File.join(policy_root, "20-resourcequota.yaml"))
  metadata!(namespace_policy, "Namespace", namespace, nil)
  metadata!(limit_policy, "LimitRange", "sandbox-limits", namespace)
  metadata!(quota_policy, "ResourceQuota", "sandbox-quota", namespace)
  limits = limit_policy.dig("spec", "limits")
  fail!("LimitRange must have one Container item") unless limits.is_a?(Array) && limits.length == 1
  policy_limit_units = limit_units(limits.first)
  contract_limit_units = limit_units(
    "type" => "Container",
    "default" => contract.dig("container_defaults", "limits"),
    "defaultRequest" => contract.dig("container_defaults", "requests"),
    "min" => contract["container_min"],
    "max" => contract["container_max"],
    "maxLimitRequestRatio" => contract["max_limit_request_ratio"]
  )
  fail!("LimitRange does not match contract") unless policy_limit_units == contract_limit_units
  policy_quota_units = quota_units(quota_policy.dig("spec", "hard") || {})
  contract_quota_units = quota_units(contract["quota"])
  fail!("ResourceQuota does not match contract") unless policy_quota_units == contract_quota_units

  usage = JSON.parse(File.read(File.join(input_root, "existing_usage.json"), encoding: "UTF-8"))
  fail!("existing usage keys mismatch") unless usage.keys == USAGE_KEYS
  fail!("existing usage must contain nonnegative integers") unless usage.values.all? { |value| value.is_a?(Integer) && value >= 0 }
  fail!("existing usage already exceeds quota") unless USAGE_KEYS.all? { |key| usage[key] <= contract_quota_units[key] }

  request_files = INPUT_FILES.grep(%r{\Arequests/})
  normalized = []
  ledger = []
  trajectory = [{ "request_id" => "INITIAL", "decision" => "BASELINE" }.merge(usage)]
  seen_request_ids = []

  request_files.each do |relative|
    object = yaml_object(File.join(input_root, relative))
    fail!("request apiVersion must be v1: #{relative}") unless object["apiVersion"] == "v1"
    kind = object["kind"]
    fail!("unsupported request kind: #{kind}") unless %w[Pod PersistentVolumeClaim].include?(kind)
    metadata = object["metadata"]
    fail!("request metadata missing: #{relative}") unless metadata.is_a?(Hash)
    fail!("request namespace mismatch: #{relative}") unless metadata["namespace"] == namespace
    request_id = metadata.dig("annotations", contract["request_id_annotation"])
    fail!("request ID missing: #{relative}") unless request_id.is_a?(String) && !request_id.empty?
    fail!("duplicate request ID: #{request_id}") if seen_request_ids.include?(request_id)
    seen_request_ids << request_id
    expected_id = contract["request_order"][seen_request_ids.length - 1]
    fail!("request ID order mismatch in #{relative}") unless request_id == expected_id

    delta = USAGE_KEYS.to_h { |key| [key, 0] }
    limit_errors = []
    if kind == "Pod"
      containers = object.dig("spec", "containers")
      fail!("Pod must have containers: #{request_id}") unless containers.is_a?(Array) && !containers.empty?
      names = containers.map { |container| container["name"] }
      fail!("container names must be nonblank and unique: #{request_id}") unless names.all? { |name| name.is_a?(String) && !name.empty? } && names.uniq.length == names.length
      delta["pods"] = 1
      containers.each do |container|
        resources = container["resources"] || {}
        fail!("resources must be a mapping: #{request_id}") unless resources.is_a?(Hash) && (resources.keys - %w[requests limits]).empty?
        requests = resources["requests"] || {}
        limits_map = resources["limits"] || {}
        fail!("requests/limits must be mappings: #{request_id}") unless requests.is_a?(Hash) && limits_map.is_a?(Hash)
        fail!("unsupported request resource: #{request_id}") unless (requests.keys - %w[cpu memory]).empty?
        fail!("unsupported limit resource: #{request_id}") unless (limits_map.keys - %w[cpu memory]).empty?

        request_cpu = requests.key?("cpu") ? cpu_m(requests["cpu"]) : contract_limit_units["request_cpu_m"]
        request_memory = requests.key?("memory") ? memory_mi(requests["memory"]) : contract_limit_units["request_memory_mi"]
        limit_cpu = limits_map.key?("cpu") ? cpu_m(limits_map["cpu"]) : contract_limit_units["limit_cpu_m"]
        limit_memory = limits_map.key?("memory") ? memory_mi(limits_map["memory"]) : contract_limit_units["limit_memory_mi"]
        [request_cpu, request_memory, limit_cpu, limit_memory].each { |value| fail!("resource quantity must be positive: #{request_id}") unless value.positive? }

        normalized << {
          "request_id" => request_id,
          "pod" => metadata["name"],
          "container" => container["name"],
          "request_cpu_m" => request_cpu,
          "request_memory_mi" => request_memory,
          "limit_cpu_m" => limit_cpu,
          "limit_memory_mi" => limit_memory,
          "request_cpu_source" => requests.key?("cpu") ? "EXPLICIT" : "DEFAULTED",
          "request_memory_source" => requests.key?("memory") ? "EXPLICIT" : "DEFAULTED",
          "limit_cpu_source" => limits_map.key?("cpu") ? "EXPLICIT" : "DEFAULTED",
          "limit_memory_source" => limits_map.key?("memory") ? "EXPLICIT" : "DEFAULTED"
        }
        limit_errors << "MIN_CPU" if request_cpu < contract_limit_units["min_cpu_m"]
        limit_errors << "MIN_MEMORY" if request_memory < contract_limit_units["min_memory_mi"]
        limit_errors << "MAX_CPU" if limit_cpu > contract_limit_units["max_cpu_m"]
        limit_errors << "MAX_MEMORY" if limit_memory > contract_limit_units["max_memory_mi"]
        limit_errors << "RATIO_CPU" if limit_cpu > contract_limit_units["ratio_cpu"] * request_cpu
        limit_errors << "RATIO_MEMORY" if limit_memory > contract_limit_units["ratio_memory"] * request_memory
        delta["requests_cpu_m"] += request_cpu
        delta["requests_memory_mi"] += request_memory
        delta["limits_cpu_m"] += limit_cpu
        delta["limits_memory_mi"] += limit_memory
      end
    else
      storage = object.dig("spec", "resources", "requests", "storage")
      fail!("PVC storage request missing: #{request_id}") if storage.nil?
      delta["persistentvolumeclaims"] = 1
      delta["requests_storage_gi"] = storage_gi(storage)
    end

    decision = "WITHIN_POLICY"
    reason = ""
    exceeded = []
    proposal = nil
    unless limit_errors.empty?
      decision = "NEEDS_CHANGE"
      reason = "LIMIT_RANGE"
      exceeded = limit_errors.uniq.sort
    end
    if decision == "WITHIN_POLICY"
      proposal = USAGE_KEYS.to_h { |key| [key, usage[key] + delta[key]] }
      exceeded = USAGE_KEYS.select { |key| proposal[key] > contract_quota_units[key] }.map do |key|
        {
          "requests_cpu_m" => "requests.cpu",
          "requests_memory_mi" => "requests.memory",
          "limits_cpu_m" => "limits.cpu",
          "limits_memory_mi" => "limits.memory",
          "requests_storage_gi" => "requests.storage"
        }.fetch(key, key)
      end.sort
      if exceeded.empty?
        usage = proposal
      else
        decision = "NEEDS_CHANGE"
        reason = "RESOURCE_QUOTA"
      end
    end

    row = {
      "request_id" => request_id,
      "kind" => kind,
      "name" => metadata["name"],
      "decision" => decision,
      "reason" => reason,
      "exceeded_resources" => exceeded.join(";")
    }
    USAGE_KEYS.each { |key| row["proposed_#{key}"] = proposal && proposal[key] }
    ledger << row
    trajectory << { "request_id" => request_id, "decision" => decision }.merge(usage)
  end

  fail!("request order does not match contract") unless seen_request_ids == contract["request_order"]
  within_policy_ids = ledger.select { |row| row["decision"] == "WITHIN_POLICY" }.map { |row| row["request_id"] }
  needs_change_ids = ledger.select { |row| row["decision"] == "NEEDS_CHANGE" }.map { |row| row["request_id"] }
  expected = contract["expected"]
  fail!("within_policy/needs_change IDs mismatch") unless within_policy_ids == expected["within_policy_ids"] && needs_change_ids == expected["needs_change_ids"]
  fail!("final usage mismatch") unless usage == expected["final_usage"]
  expected["issues"].each do |request_id, rule|
    row = ledger.find { |item| item["request_id"] == request_id }
    fail!("rejection mismatch for #{request_id}") unless row && row["reason"] == rule["reason"] && row["exceeded_resources"].split(";") == rule["exceeded_resources"]
  end

  kubectl = ENV.fetch("KUBECTL_BIN", "kubectl")
  parent = File.dirname(output_root)
  FileUtils.mkdir_p(parent)
  stage = Dir.mktmpdir(".#{File.basename(output_root)}.staging.", parent)
  begin
    kubeconfig_argument = "--kubeconfig=#{ENV.fetch("KUBECONFIG")}" 
    version_text = kubectl!(kubectl, "version", "--client", "--output=json", kubeconfig_argument)
    version = JSON.parse(version_text).dig("clientVersion", "gitVersion")
    fail!("kubectl 1.32 required, got #{version}") unless version.to_s.match?(/\Av1\.32\./)
    namespace_yaml = kubectl!(kubectl, "create", "namespace", namespace, "--dry-run=client", "-o", "yaml", kubeconfig_argument)
    hard_argument = contract["quota"].map { |key, value| "#{key}=#{value}" }.join(",")
    quota_yaml = kubectl!(kubectl, "create", "quota", "sandbox-quota", "--namespace=#{namespace}", "--hard=#{hard_argument}", "--dry-run=client", "-o", "yaml", kubeconfig_argument)
    generated_namespace = yaml_text(namespace_yaml, "kubectl namespace output")
    generated_quota = yaml_text(quota_yaml, "kubectl quota output")
    metadata!(generated_namespace, "Namespace", namespace, nil)
    metadata!(generated_quota, "ResourceQuota", "sandbox-quota", namespace)
    fail!("generated quota differs semantically") unless quota_units(generated_quota.dig("spec", "hard") || {}) == contract_quota_units

    normalized_headers = %w[
      request_id pod container request_cpu_m request_memory_mi limit_cpu_m limit_memory_mi
      request_cpu_source request_memory_source limit_cpu_source limit_memory_source
    ]
    ledger_headers = %w[
      request_id kind name decision reason exceeded_resources proposed_pods
      proposed_requests_cpu_m proposed_requests_memory_mi proposed_limits_cpu_m
      proposed_limits_memory_mi proposed_persistentvolumeclaims proposed_requests_storage_gi
    ]
    trajectory_headers = %w[
      request_id decision pods requests_cpu_m requests_memory_mi limits_cpu_m
      limits_memory_mi persistentvolumeclaims requests_storage_gi
    ]
    write_csv(File.join(stage, "normalized_containers.csv"), normalized_headers, normalized)
    write_csv(File.join(stage, "request_precheck.csv"), ledger_headers, ledger)
    write_csv(File.join(stage, "quota_trajectory.csv"), trajectory_headers, trajectory)
    File.binwrite(File.join(stage, "kubectl_namespace_dry_run.yaml"), namespace_yaml)
    File.binwrite(File.join(stage, "kubectl_quota_dry_run.yaml"), quota_yaml)
    json_write(File.join(stage, "final_usage.json"), usage)

    summary = {
      "contract_id" => contract["contract_id"],
      "kubectl_version" => version,
      "requests" => ledger.length,
      "containers" => normalized.length,
      "within_policy" => within_policy_ids.length,
      "needs_change" => needs_change_ids.length,
      "within_policy_ids" => within_policy_ids,
      "needs_change_ids" => needs_change_ids,
      "trajectory_rows" => trajectory.length,
      "final_usage" => usage
    }
    json_write(File.join(stage, "precheck_summary.json"), summary)
    fail!("staged result boundary mismatch") unless inventory(stage) == RESULT_FILES
    Dir.rmdir(output_root) if File.directory?(output_root)
    File.rename(stage, output_root)
    stage = nil
  ensure
    FileUtils.rm_rf(stage) if stage && File.exist?(stage)
  end
end

if ARGV.length != 3
  warn "usage: build_precheck.rb INPUT_ROOT POLICY_ROOT OUTPUT_ROOT"
  exit 2
end

begin
  run(*ARGV.map { |value| File.expand_path(value) })
rescue StandardError => error
  warn "kubernetes_internet_sandbox_precheck build failed: #{error.message}"
  exit 2
end
