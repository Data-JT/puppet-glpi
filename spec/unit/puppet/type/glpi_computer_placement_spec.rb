# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_computer_placement'

RSpec.describe 'the glpi_computer_placement type' do
  let(:type) { Puppet::Type.type(:glpi_computer_placement) }
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

  it 'has no ensure: it never creates or deletes computers' do
    expect(definition.ensurable?).to be false
  end

  it 'accepts name, entity and location' do
    resource = type.new(name: 'web1.example.com', entity: 'Root entity > Customers > Customer A', location: 'Main office')
    expect([resource[:entity], resource[:location]]).to eq(['Root entity > Customers > Customer A', 'Main office'])
  end

  it 'accepts entity_tag instead of entity' do
    resource = type.new(name: 'web1.example.com', entity_tag: '10001')
    expect(resource[:entity_tag]).to eq('10001')
  end

  it 'refuses entity and entity_tag together' do
    expect {
      type.new(name: 'web1.example.com', entity: 'Customer A', entity_tag: '10001')
    }.to raise_error(Puppet::ResourceError, %r{entity and entity_tag are mutually exclusive})
  end
end
