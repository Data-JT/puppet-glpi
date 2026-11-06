# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_config'

RSpec.describe 'the glpi_config type' do
  let(:type) { Puppet::Type.type(:glpi_config) }
  let(:definition) { type.type_definition }

  it 'loads' do
    expect(type).not_to be_nil
  end

  it 'declares the features the base provider relies on' do
    expect(definition.feature?('simple_get_filter')).to be true
    expect(definition.feature?('custom_insync')).to be true
  end

  it 'autorequires the transport file and installs the deletion-plan hook' do
    expect(type.ancestors).to include(Puppet::Type::GlpiTransportAutorequire::DeletionPlanHook)
  end

  it 'has no ensure: it never creates or deletes configuration keys' do
    expect(definition.ensurable?).to be false
  end

  it 'name splits into context and key' do
    resource = type.new(name: 'inventory/stale_agents_delay', value: '14')
    expect(resource[:name]).to eq('inventory/stale_agents_delay')
    expect(resource[:name].split('/', 2)).to eq(['inventory', 'stale_agents_delay'])
  end

  it 'refuses a name that is not <context>/<key>' do
    ['stale_agents_delay', 'a/b/c', '/key', 'ctx/', 'ctx/ key'].each do |bad|
      expect { type.new(name: bad, value: '1') }.to raise_error(Puppet::ResourceError, %r{<context>/<key>})
    end
  end

  it 'refuses keys that hold secrets' do
    ['inventory/basic_auth_password', 'core/smtp_passwd', 'core/api_token', 'core/some_secret', 'core/private_key'].each do |bad|
      expect { type.new(name: bad, value: 'x') }.to raise_error(Puppet::ResourceError, %r{secret})
    end
  end

  it 'refuses by name alone, so harmless policy keys that mention a password are refused too' do
    expect { type.new(name: 'core/password_min_length', value: '8') }.to raise_error(Puppet::ResourceError)
  end

  it 'takes the value as a string' do
    expect { type.new(name: 'core/cut', value: 250) }.to raise_error(Puppet::ResourceError)
    expect(type.new(name: 'core/cut', value: '250')[:value]).to eq('250')
  end
end
