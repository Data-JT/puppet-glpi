# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_cluster'

RSpec.describe 'the glpi_cluster type' do
  let(:type) { Puppet::Type.type(:glpi_cluster) }
  let(:definition) { type.type_definition }

  it 'declares the features the base provider relies on' do
    expect(definition.feature?('simple_get_filter')).to be true
    expect(definition.feature?('custom_insync')).to be true
  end

  it 'autorequires the transport file and installs the deletion-plan hook' do
    expect(type.ancestors).to include(Puppet::Type::GlpiTransportAutorequire::DeletionPlanHook)
  end

  it 'accepts name, cluster_type and comment' do
    resource = type.new(name: 'Cluster A', cluster_type: 'Hypervisor', comment: 'Three nodes')
    expect([resource[:cluster_type], resource[:comment]]).to eq(['Hypervisor', 'Three nodes'])
  end

  it 'has no members attribute (the API cannot read or write cluster membership)' do
    expect(definition.attributes).not_to have_key(:members)
  end
end
