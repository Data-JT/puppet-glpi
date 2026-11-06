# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_domain'

RSpec.describe 'the glpi_domain type' do
  let(:type) { Puppet::Type.type(:glpi_domain) }
  let(:definition) { type.type_definition }

  it 'declares the features the base provider relies on' do
    expect(definition.feature?('simple_get_filter')).to be true
    expect(definition.feature?('custom_insync')).to be true
  end

  it 'autorequires the transport file and installs the deletion-plan hook' do
    expect(type.ancestors).to include(Puppet::Type::GlpiTransportAutorequire::DeletionPlanHook)
  end

  it 'needs nothing but the name, which keeps Unicode as declared' do
    resource = type.new(Puppet::Resource.new(:glpi_domain, 'café.example'))
    expect(resource.instance_variable_get(:@missing_attrs)).to eq([])
    expect(resource[:name]).to eq('café.example')
  end

  it 'accepts YYYY-MM-DD or an empty expiration only' do
    expect(type.new(title: 'a', expiration: '')[:expiration]).to eq('')
    expect { type.new(title: 'a', expiration: '2027-02-28 00:00:00') }.to raise_error(Puppet::ResourceError)
  end

  it 'hands the provider contracts and contract_scope before reading' do
    resource = type.new(title: 'example.com', contracts: ['Hosting A'], contract_scope: ['Hosting A', 'Hosting B'])
    provider = resource.my_provider
    expect(provider).to receive(:declare_contracts).with('example.com', ['Hosting A'], ['Hosting A', 'Hosting B'])
    allow(provider).to receive(:get).and_return([])
    resource.refresh_current_state
  end

  it 'refuses entity and entity_tag together' do
    expect { type.new(title: 'a', entity: 'Customer A', entity_tag: '10001') }
      .to raise_error(Puppet::ResourceError, %r{entity and entity_tag are mutually exclusive})
  end
end
