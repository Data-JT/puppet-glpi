# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_appliance'

RSpec.describe 'the glpi_appliance type' do
  let(:type) { Puppet::Type.type(:glpi_appliance) }
  let(:definition) { type.type_definition }

  it 'declares the features the base provider relies on' do
    expect(definition.feature?('simple_get_filter')).to be true
    expect(definition.feature?('custom_insync')).to be true
  end

  it 'autorequires the transport file and installs the deletion-plan hook' do
    expect(type.ancestors).to include(Puppet::Type::GlpiTransportAutorequire::DeletionPlanHook)
  end

  it 'accepts type, environment, comment, members and member_types' do
    resource = type.new(name: 'Web shop', appliance_type: 'Service', environment: 'Production', comment: 'Shop',
                        members: [{ 'itemtype' => 'Computer', 'name' => 'web1.example.com' }],
                        member_types: ['Computer', 'Cluster'])
    expect(resource[:members]).to eq([{ 'itemtype' => 'Computer', 'name' => 'web1.example.com' }])
    expect(resource[:member_types]).to eq(['Computer', 'Cluster'])
  end

  it 'defaults member_types to Computer' do
    expect(type.new(name: 'Web shop')[:member_types]).to eq(['Computer'])
  end

  it 'rejects an unsupported itemtype' do
    expect { type.new(name: 'Web shop', member_types: ['Ticket']) }.to raise_error(Puppet::ResourceError, %r{member_types})
    expect { type.new(name: 'Web shop', members: [{ 'itemtype' => 'Ticket', 'name' => 'x' }]) }
      .to raise_error(Puppet::ResourceError, %r{members})
  end

  it 'hands the provider the declared member_types before reading the current state' do
    provider = instance_double('Puppet::Provider::GlpiAppliance::GlpiAppliance', get: [])
    allow(type).to receive_messages(my_provider: provider, context: instance_double('Puppet::ResourceApi::BaseContext'))
    expect(provider).to receive(:declare_member_types).with('Web shop', ['Cluster']).ordered
    expect(provider).to receive(:get).ordered.and_return([])
    type.new(name: 'Web shop', member_types: ['Cluster']).retrieve
  end
end
