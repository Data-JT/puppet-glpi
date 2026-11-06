# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_rule'

RSpec.describe 'the glpi_rule type' do
  let(:type) { Puppet::Type.type(:glpi_rule) }
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

  it 'defaults match to AND and is_active to true' do
    expect(definition.attributes[:match][:default]).to eq('AND')
    expect(definition.attributes[:is_active][:default]).to be true
  end

  it 'accepts a complete rule' do
    resource = type.new(
      name: 'Staff rule', collection: 'right',
      criteria: [{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'example-group' }],
      actions: [{ 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Technician' }],
      before_rule: 'Other rule'
    )
    expect(resource[:collection]).to eq('right')
    expect(resource[:before_rule]).to eq('Other rule')
  end

  it 'rejects an unknown collection' do
    expect { type.new(name: 'Staff rule', collection: 'ticket', criteria: [], actions: []) }
      .to raise_error(Puppet::ResourceError, %r{collection})
  end

  it 'rejects a criterion whose condition is not an Integer' do
    expect {
      type.new(name: 'Staff rule', collection: 'right', actions: [],
               criteria: [{ 'criteria' => 'memberof', 'condition' => 'contains', 'pattern' => 'x' }])
    }.to raise_error(Puppet::ResourceError, %r{criteria})
  end
end
