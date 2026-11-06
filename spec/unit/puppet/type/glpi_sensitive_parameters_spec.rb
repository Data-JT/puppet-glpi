# frozen_string_literal: true

require 'spec_helper'

# The sibling modules redact secret attributes through a <prefix>_sensitive_parameters
# helper. No glpi_* type holds a secret, so this module has none. The transport
# file carries the only credentials, and class glpi writes it as Sensitive.
# This pins that: a secret attribute added later must fail here and bring the
# helper along, because the schema's `sensitive: true` alone does not stop
# Puppet printing the value in a change event.
RSpec.describe 'secrets in glpi_* types' do
  types = [:glpi_appliance, :glpi_certificate, :glpi_cluster, :glpi_computer_placement, :glpi_config,
           :glpi_custom_asset, :glpi_domain, :glpi_item_placement, :glpi_location, :glpi_rule]

  it 'lists every registered type' do
    registered = Dir[File.expand_path('../../../../lib/puppet/type/glpi_*.rb', __dir__)].map { |file| File.basename(file, '.rb').to_sym }
    expect(registered - [:glpi_transport_autorequire]).to match_array(types)
  end

  types.each do |type_name|
    describe type_name do
      let(:attributes) do
        require "puppet/type/#{type_name}"
        Puppet::Type.type(type_name).type_definition.attributes
      end

      it 'flags no attribute sensitive' do
        expect(attributes.select { |_name, options| options[:sensitive] }).to be_empty
      end

      it 'has no attribute named like a secret' do
        expect(attributes.keys.grep(%r{pass|secret|token|credential|pwd}i)).to be_empty
      end
    end
  end
end
