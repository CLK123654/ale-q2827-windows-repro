require "fileutils"
require "json"
require "pathname"
require "rbconfig"
require "tmpdir"


def required_path(name)
  value = ENV[name]
  raise "#{name} is required" if value.nil? || value.empty?
  File.expand_path(value)
end


def files_under(root)
  Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
    .select { |path| File.file?(path) }
    .map { |path| Pathname.new(path).relative_path_from(Pathname.new(root)).to_s.tr("\\", "/") }
    .sort
end


reference_root = required_path("ALE_REFERENCE_ROOT")
runtime_root = File.expand_path(__dir__)
input_root = required_path("ALE_INPUT_ROOT")
output_root = required_path("ALE_OUTPUT_ROOT")
kubectl_bin = required_path("KUBECTL_BIN")
ruby_bin = ENV.fetch("RUBY_BIN", RbConfig.ruby)
policy_root = File.join(reference_root, "policy")

raise "ALE_INPUT_ROOT must be a directory" unless File.directory?(input_root)
raise "KUBECTL_BIN must be a file" unless File.file?(kubectl_bin)
raise "input, Reference and output roots must be distinct" if [input_root, reference_root, output_root].uniq.length != 3
output_path = Pathname.new(output_root)
raise "output root must not be nested inside input or Reference" if output_path.to_s.start_with?("#{input_root}#{File::SEPARATOR}") || output_path.to_s.start_with?("#{reference_root}#{File::SEPARATOR}")
if File.exist?(output_root)
  raise "ALE_OUTPUT_ROOT must be an empty directory" unless File.directory?(output_root) && Dir.children(output_root).empty?
end

contract = JSON.parse(File.read(File.join(input_root, "precheck_contract.json"), encoding: "UTF-8"))
expected_results = contract.fetch("exact_result_files").sort
parent = File.dirname(output_root)
FileUtils.mkdir_p(parent)
work_root = Dir.mktmpdir(".kubernetes-precheck-", parent)
candidate = File.join(work_root, "candidate-results")
kubeconfig = File.join(work_root, "empty-kubeconfig")
File.write(kubeconfig, "")
environment = {
  "KUBECTL_BIN" => kubectl_bin,
  "KUBECONFIG" => kubeconfig,
  "RUBYOPT" => ENV.fetch("RUBYOPT", "")
}
published = false

begin
  build = File.join(runtime_root, "build_precheck.rb")
  raise "build failed" unless system(environment, ruby_bin, build, input_root, policy_root, candidate)
  raise "candidate result boundary differs from contract" unless files_under(candidate) == expected_results
  Dir.rmdir(output_root) if File.directory?(output_root)
  File.rename(candidate, output_root)
  published = true
ensure
  FileUtils.rm_rf(work_root)
end

raise "results were not published" unless published
