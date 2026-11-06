# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'glpi::resources', type: :class do
  let(:pre_condition) do
    "class { 'glpi': base_url => 'https://glpi.example.com/api.php', client_id => 'puppet', " \
      "client_secret => Sensitive('x'), username => 'puppet-api', password => Sensitive('y') }"
  end

  # A relationship that compiles can still fail at the agent: the RAL catalog
  # titles a resource its own way, and a reference to a title it does not
  # know fails the whole run.
  def relationships_resolve
    ral = catalogue.to_ral
    ral.resources.each { |resource| resource.builddepends.each { |edge| expect(edge.source).not_to eq(edge.target) } }
    ral
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      context 'with no data (defaults)' do
        it { is_expected.to compile.with_all_deps }

        it 'declares no glpi_* resource' do
          expect(catalogue.resources.map(&:type).grep(%r{\AGlpi_})).to be_empty
        end
      end

      context 'with one entry of every type' do
        let(:params) do
          {
            appliances: { 'Web shop' => { 'appliance_type' => 'Service' } },
            certificates: { 'www.example.com' => { 'serial' => '04A1' } },
            clusters: { 'Cluster A' => { 'cluster_type' => 'Hypervisor' } },
            computer_placements: { 'web1.example.com' => { 'entity' => 'Root entity' } },
            configs: { 'inventory/stale_agents_delay' => { 'value' => '14' } },
            custom_assets: { 'Website/www.example.com' => { 'comment' => 'Main site' } },
            domains: { 'example.com' => { 'expiration' => '2027-02-28' } },
            item_placements: { 'NetworkEquipment/switch1' => { 'location' => 'Elsewhere' } },
            locations: { 'Main office' => { 'comment' => 'Head office' } },
            rules: { 'Staff rule' => { 'collection' => 'right', 'criteria' => [], 'actions' => [] } },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_glpi_appliance('Web shop').with_appliance_type('Service') }
        it { is_expected.to contain_glpi_certificate('www.example.com').with_serial('04A1') }
        it { is_expected.to contain_glpi_cluster('Cluster A').with_cluster_type('Hypervisor') }
        it { is_expected.to contain_glpi_computer_placement('web1.example.com').with_entity('Root entity') }
        it { is_expected.to contain_glpi_config('inventory/stale_agents_delay').with_value('14') }
        it { is_expected.to contain_glpi_custom_asset('Website/www.example.com').with_comment('Main site') }
        it { is_expected.to contain_glpi_domain('example.com').with_expiration('2027-02-28') }
        it { is_expected.to contain_glpi_item_placement('NetworkEquipment/switch1').with_location('Elsewhere') }
        it { is_expected.to contain_glpi_location('Main office').with_comment('Head office') }
        it { is_expected.to contain_glpi_rule('Staff rule').with_collection('right') }

        it 'adds no ordering between unrelated entries' do
          expect(catalogue.resource('Glpi_item_placement', 'NetworkEquipment/switch1')[:require]).to be_nil
        end
      end

      context 'with placements naming a declared location' do
        let(:params) do
          {
            locations: { 'Main office' => {} },
            computer_placements: { 'web1.example.com' => { 'location' => 'Main office' } },
            item_placements: { 'DataCenter/dc1' => { 'location' => 'Main office' } },
          }
        end

        it { is_expected.to contain_glpi_location('Main office').that_comes_before('Glpi_computer_placement[web1.example.com]') }
        it { is_expected.to contain_glpi_location('Main office').that_comes_before('Glpi_item_placement[DataCenter/dc1]') }
        it { expect(relationships_resolve).not_to be_nil }
      end

      context 'with a location name differing only in case' do
        let(:params) do
          {
            locations: { 'Main office' => {} },
            computer_placements: { 'web1.example.com' => { 'location' => 'MAIN OFFICE' } },
          }
        end

        it { is_expected.to compile.with_all_deps }
      end

      context 'with a nested location and its parent' do
        let(:params) { { locations: { 'Main office' => {}, 'Main office > Server room' => { 'comment' => 'Basement' } } } }

        it { is_expected.to contain_glpi_location('Main office').that_comes_before('Glpi_location[Main office > Server room]') }
        it { expect(relationships_resolve).not_to be_nil }
      end

      context 'with a location title containing a bare >' do
        let(:params) { { locations: { 'Rack >A' => {} } } }

        it { is_expected.to compile.with_all_deps }
        it { expect(relationships_resolve).not_to be_nil }
      end

      context 'with a location naming its parent by attribute' do
        let(:params) { { locations: { 'Main office' => {}, 'Server room' => { 'parent' => 'Main office' } } } }

        it { is_expected.to contain_glpi_location('Main office').that_comes_before('Glpi_location[Server room]') }
      end

      context 'with a chain of locations naming their parents by attribute' do
        let(:params) { { locations: { 'C' => { 'parent' => 'A > B' }, 'B' => { 'parent' => 'A' }, 'A' => {} } } }

        it { is_expected.to contain_glpi_location('A').that_comes_before('Glpi_location[B]') }
        it { is_expected.to contain_glpi_location('B').that_comes_before('Glpi_location[C]') }
      end

      # A > B and B > A are two valid locations; the same name as a parent is
      # not a reference to itself.
      context 'with locations that name each other as parent' do
        let(:params) { { locations: { 'A' => { 'parent' => 'B' }, 'B' => { 'parent' => 'A' } } } }

        it { is_expected.to compile.with_all_deps }
        it { expect(relationships_resolve).not_to be_nil }
      end

      context 'with a location named like its parent' do
        let(:params) { { locations: { 'A' => { 'parent' => 'A' } } } }

        it { is_expected.to compile.with_all_deps }
        it { expect(relationships_resolve).not_to be_nil }
      end

      context 'with a placement naming a location by complete name' do
        let(:params) do
          {
            locations: { 'Main office' => {}, 'Server room' => { 'parent' => 'Main office' } },
            computer_placements: { 'web1.example.com' => { 'location' => 'Main office > Server room' } },
          }
        end

        it { is_expected.to contain_glpi_location('Server room').that_comes_before('Glpi_computer_placement[web1.example.com]') }
      end

      context 'with a rule ranked above itself' do
        let(:params) { { rules: { 'First' => { 'collection' => 'right', 'criteria' => [], 'actions' => [], 'before_rule' => 'First' } } } }

        it { is_expected.to compile.with_all_deps }
        it { expect(relationships_resolve).not_to be_nil }
      end

      context 'with a rule ranked above another entry' do
        let(:params) do
          {
            rules: {
              'First' => { 'collection' => 'import_asset', 'criteria' => [], 'actions' => [], 'before_rule' => 'Second' },
              'Second' => { 'collection' => 'import_asset', 'criteria' => [], 'actions' => [] },
            },
          }
        end

        it { is_expected.to contain_glpi_rule('Second').that_comes_before('Glpi_rule[First]') }
        it { expect(relationships_resolve).not_to be_nil }
      end

      context 'with a before_rule outside the data' do
        let(:params) { { rules: { 'First' => { 'collection' => 'right', 'criteria' => [], 'actions' => [], 'before_rule' => 'Other' } } } }

        it { is_expected.to compile.with_all_deps }
      end

      context 'with a type the class does not know about in an entry' do
        let(:params) { { clusters: { 'Cluster A' => { 'no_such_attribute' => 'x' } } } }

        it { is_expected.to compile.and_raise_error(%r{no_such_attribute}) }
      end
    end
  end
end
