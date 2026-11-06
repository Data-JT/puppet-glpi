# frozen_string_literal: true

require 'bundler'
require 'puppet_litmus/rake_tasks' if Gem.loaded_specs.key? 'puppet_litmus'
require 'puppetlabs_spec_helper/rake_tasks'
require 'puppet-syntax/tasks/puppet-syntax'
require 'puppet-strings/tasks' if Gem.loaded_specs.key? 'puppet-strings'
require 'fileutils'
require 'json'

PuppetLint.configuration.send('disable_relative')
PuppetLint.configuration.send('disable_80chars')
PuppetLint.configuration.send('disable_140chars')
PuppetLint.configuration.send('disable_class_inherits_from_params_class')
PuppetLint.configuration.send('disable_autoloader_layout')
PuppetLint.configuration.send('disable_documentation')
PuppetLint.configuration.send('disable_single_quote_string_with_variables')
PuppetLint.configuration.fail_on_warnings = true
PuppetLint.configuration.ignore_paths = [".vendor/**/*.pp", ".bundle/**/*.pp", "pkg/**/*.pp", "spec/**/*.pp", "tests/**/*.pp", "types/**/*.pp", "vendor/**/*.pp"]

if Gem.loaded_specs.key? 'reek'
  require 'reek/rake/task'
  Reek::Rake::Task.new do |t|
    t.source_files = 'lib/**/*.rb'
  end
end

namespace :quality do
  desc 'Enforce the configured RuboCop offense baseline'
  task :rubocop do
    baseline = Integer(ENV.fetch('RUBOCOP_BASELINE', '0'))
    report = 'tmp/rubocop.json'
    FileUtils.mkdir_p(File.dirname(report))
    system('rubocop', '--format', 'json', out: report)
    offenses = JSON.parse(File.read(report)).fetch('summary').fetch('offense_count')
    abort "RuboCop found #{offenses} offenses, exceeding baseline #{baseline}" if offenses > baseline

    puts "RuboCop offenses: #{offenses} (baseline: #{baseline})"
  end
end
