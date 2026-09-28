#!/usr/bin/env ruby
# Compare GitHub's PR job names with the reviewable .github-guard declaration.
# Only literal matrices are accepted: a dynamic matrix cannot be proven to
# match a static branch-protection list before the workflow runs.
require 'open3'
require 'yaml'

class ProfileError < StandardError; end

root = ARGV[0] ? File.expand_path(ARGV[0]) : File.expand_path('..', __dir__)
guard = File.join(root, '.github-guard')

read_checks = lambda do |key, optional|
  output, error, status = Open3.capture3('git', 'config', '-f', guard, '--get-all', "checks.#{key}")
  if status.exitstatus == 1 && optional
    []
  elsif !status.success?
    raise ProfileError, "cannot read checks.#{key} from .github-guard: #{error.strip}"
  else
    output.lines.map(&:strip)
  end
end

begin
  required = read_checks.call('required', false)
  advisory = read_checks.call('advisory', true)
  raise ProfileError, 'checks.required is empty' if required.empty?
  declared = required + advisory
  raise ProfileError, 'blank check declaration' if declared.any?(&:empty?)
  duplicates = declared.tally.select { |_name, count| count > 1 }.keys
  raise ProfileError, "duplicate check declaration: #{duplicates.join(', ')}" unless duplicates.empty?

  workflows = Dir.glob(File.join(root, '.github/workflows/*.{yml,yaml}')).sort
  raise ProfileError, 'no workflow files found' if workflows.empty?
  produced = []

  workflows.each do |path|
    workflow = YAML.safe_load_file(path, aliases: false)
    raise ProfileError, "#{path}: expected a workflow mapping" unless workflow.is_a?(Hash)
    # Psych implements YAML 1.1 and parses an unquoted `on` key as true.
    events = workflow.key?('on') ? workflow['on'] : workflow[true]
    pull_request = case events
                   when String then events == 'pull_request'
                   when Array then events.include?('pull_request')
                   when Hash then events.key?('pull_request')
                   else false
                   end
    next unless pull_request

    jobs = workflow['jobs']
    raise ProfileError, "#{path}: pull_request workflow has no jobs mapping" unless jobs.is_a?(Hash)
    jobs.each do |id, job|
      raise ProfileError, "#{path}: #{id} must be a job mapping" unless job.is_a?(Hash)
      raise ProfileError, "#{path}: reusable job #{id} needs explicit review" if job.key?('uses')
      name = job.fetch('name', id)
      raise ProfileError, "#{path}: #{id} has a non-string job name" unless name.is_a?(String)
      matrix = job.fetch('strategy', {})&.fetch('matrix', nil)
      if matrix.nil?
        raise ProfileError, "#{path}: #{id} has an unexpanded expression in its name" if name.include?('${{')
        produced << name
        next
      end
      raise ProfileError, "#{path}: #{id} matrix must be a mapping" unless matrix.is_a?(Hash)
      if matrix.key?('include') || matrix.key?('exclude')
        raise ProfileError, "#{path}: #{id} matrix include/exclude needs explicit review"
      end
      axes = matrix.map do |axis, values|
        unless values.is_a?(Array) && !values.empty? && values.all? { |value| value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false }
          raise ProfileError, "#{path}: #{id} matrix axis #{axis} must be a nonempty literal list"
        end
        [axis.to_s, values]
      end
      raise ProfileError, "#{path}: #{id} matrix has no axes" if axes.empty?
      combinations = axes.reduce([{}]) do |partial, (axis, values)|
        partial.flat_map { |entry| values.map { |value| entry.merge(axis => value) } }
      end
      combinations.each do |entry|
        expanded = name.gsub(/\$\{\{\s*matrix\.([\w-]+)\s*\}\}/) do
          axis = Regexp.last_match(1)
          raise ProfileError, "#{path}: #{id} names unknown matrix axis #{axis}" unless entry.key?(axis)
          entry.fetch(axis).to_s
        end
        raise ProfileError, "#{path}: #{id} has an unexpanded expression in its name" if expanded.include?('${{')
        expanded = "#{expanded} (#{entry.values.join(', ')})" if expanded == name
        produced << expanded
      end
    end
  end

  duplicate_jobs = produced.tally.select { |_name, count| count > 1 }.keys
  raise ProfileError, "duplicate pull-request job name: #{duplicate_jobs.join(', ')}" unless duplicate_jobs.empty?

  missing = required - produced
  stale_advisory = advisory - produced
  undeclared = produced - declared
  problems = missing.map { |name| "no pull-request job produces: #{name}" } +
             stale_advisory.map { |name| "advisory check has no pull-request job: #{name}" } +
             undeclared.map { |name| "undeclared pull-request job: #{name}" }
  unless problems.empty?
    warn problems.sort.join("\n")
    exit 1
  end

  puts "required checks match #{produced.length} pull-request job(s) (#{required.length} required, #{advisory.length} advisory)"
rescue ProfileError, Psych::Exception => error
  warn "required-checks: #{error.message}"
  exit 1
end
