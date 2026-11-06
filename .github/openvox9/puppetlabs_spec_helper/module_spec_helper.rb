# frozen_string_literal: true

# Stands in for puppetlabs_spec_helper, which pins the puppet gem, in the OpenVox 9 job.
require 'rspec-puppet'

fixture_path = File.expand_path(File.join(Dir.pwd, 'spec', 'fixtures'))

RSpec.configure do |c|
  c.module_path = File.join(fixture_path, 'modules')
  c.manifest = File.join(fixture_path, 'manifests', 'site.pp')
end
