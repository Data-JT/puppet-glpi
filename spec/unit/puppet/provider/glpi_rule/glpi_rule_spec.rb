# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../../lib/puppet/provider/glpi_rule/glpi_rule'

# Spies (have_received): the transport stubs simulate GLPI's state across
# calls, so expectations are checked after the call against one stub per path.
# rubocop:disable RSpec/MessageSpies
RSpec.describe Puppet::Provider::GlpiRule::GlpiRule do
  subject(:provider) { described_class.new }

  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-rule-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password',
      'marker' => marker, 'purge_max_fraction' => 0.5
    }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:type) do
    instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_rule', namevars: [:name], ensurable?: true)
  end
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }

  let(:right_path) { '/Rule/Collection/Right/Rule' }
  let(:import_path) { '/Rule/Collection/ImportAsset/Rule' }
  let(:mail_path) { '/Rule/Collection/MailCollector/Rule' }

  let(:profiles) { [{ 'id' => 3, 'name' => 'Admin' }, { 'id' => 6, 'name' => 'Technician' }] }
  let(:entities) do
    [{ 'id' => 0, 'name' => 'Root entity' },
     { 'id' => 5, 'name' => 'Customer A', 'completename' => 'Root entity > Customer A' }]
  end

  # API v2 shape, with numbers and booleans partly as strings as the API may send them.
  let(:staff_rule) do
    {
      'id' => 10, 'name' => 'Staff rule', 'ranking' => 3, 'is_active' => '1', 'match' => 'AND',
      'condition' => 0, 'comment' => marker,
      'criteria' => [{ 'id' => 1, 'criteria' => 'memberof', 'condition' => '2', 'pattern' => 'example-group' }],
      'actions' => [
        { 'id' => 2, 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 6 },
        { 'id' => 3, 'action_type' => 'assign', 'field' => 'is_recursive', 'value' => '1' },
      ]
    }
  end
  let(:hand_made) do
    {
      'id' => 11, 'name' => 'Hand made', 'ranking' => 1, 'is_active' => true, 'match' => 'OR',
      'condition' => 0, 'comment' => 'made by hand',
      'criteria' => [{ 'id' => 4, 'criteria' => 'memberof', 'condition' => 0, 'pattern' => 'old-group' }],
      'actions' => [{ 'id' => 5, 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => '3' }]
    }
  end
  let(:device_rule) do
    { 'id' => 20, 'name' => 'Device update', 'ranking' => 36, 'is_active' => true, 'match' => 'AND',
      'condition' => 0, 'comment' => '', 'criteria' => [], 'actions' => [] }
  end
  let(:lamp_rule) do
    {
      'id' => 21, 'name' => 'Ignore lamps', 'ranking' => 40, 'is_active' => true, 'match' => 'AND',
      'condition' => 0, 'comment' => marker,
      'criteria' => [{ 'id' => 7, 'criteria' => 'name', 'condition' => 6, 'pattern' => '/Lamp$/' }],
      'actions' => [{ 'id' => 8, 'action_type' => 'assign', 'field' => '_ignore_import', 'value' => '1' }]
    }
  end
  let(:collections) { { right_path => [staff_rule, hand_made], import_path => [device_rule, lamp_rule], mail_path => [] } }

  let(:staff_should) do
    {
      name: 'Staff rule', ensure: 'present', collection: 'right', match: 'AND', is_active: true,
      criteria: [{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'example-group' }],
      actions: [
        { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Technician' },
        { 'action_type' => 'assign', 'field' => 'is_recursive', 'value' => '1' },
      ]
    }
  end

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(described_class).to receive_messages(config_path: config_file, build_transport: transport)
    collections.each_key do |path|
      allow(transport).to receive(:get_all).with(context, path, anything) { collections[path].map { |rule| Marshal.load(Marshal.dump(rule)) } }
    end
    allow(transport).to receive(:get) do |_c, p, _q = nil|
      rule = collections.flat_map { |cp, rules| rules.select { |r| "#{cp}/#{r['id']}" == p } }.first
      rule && Marshal.load(Marshal.dump(rule))
    end
    allow(transport).to receive(:get_all).with(context, '/Administration/Profile', anything) { profiles }
    allow(transport).to receive(:get_all).with(context, '/Administration/Entity', anything) { entities }
    allow(transport).to receive(:post)
    allow(transport).to receive(:patch)
    allow(transport).to receive(:delete)
    allow(type).to receive(:feature?).and_return(false)
    allow(type).to receive(:feature?).with('simple_get_filter').and_return(true)
    allow(type).to receive(:check_schema)
    [:debug, :info, :notice, :warning].each { |level| allow(context).to receive(level) }
    [:creating, :updating, :deleting].each { |action| allow(context).to receive(action).and_yield }
  end

  after(:each) { FileUtils.remove_entry(config_dir) }

  def resource_of(name)
    provider.get(context, [name]).first
  end

  it 'can be loaded twice without constant warnings (Puppet loads provider files more than once)' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_rule/glpi_rule.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  describe 'get' do
    it 'matches a rule whose name differs only in case, keeping the declared name' do
      expect(provider.get(context, ['STAFF rule']).first).to include(name: 'STAFF rule', collection: 'right')
    end

    it 'does not rename a rule whose name differs only in case when it is written' do
      should = staff_should.merge(name: 'STAFF rule')
      provider.update(context, 'STAFF rule', should)
      expect(transport).to have_received(:patch).with(context, "#{right_path}/#{staff_rule['id']}", hash_not_including('name'))
    end

    it 'fails a name that two rules of the collection match in different case' do
      collections[right_path] << staff_rule.merge('id' => 99, 'name' => 'staff RULE')
      expect { provider.get(context, ['Staff rule']) }.to raise_error(Puppet::ResourceError, %r{ids })
    end

    it 'get maps API rule + criteria + actions to the struct shape with string keys' do
      expect(provider.get(context, ['Staff rule'])).to eq(
        [{
          name: 'Staff rule', ensure: 'present', collection: 'right', match: 'AND', is_active: true,
          criteria: [{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'example-group' }],
          actions: [
            { 'action_type' => 'assign', 'field' => 'is_recursive', 'value' => '1' },
            { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Technician' },
          ]
        }],
      )
    end

    it 'lists only marked rules, across all supported collections, when called without names' do
      expect(provider.get(context, []).map { |r| [r[:name], r[:collection]] })
        .to contain_exactly(['Staff rule', 'right'], ['Ignore lamps', 'import_asset'])
    end

    it 'reads an entities_id action value back as the entity name' do
      staff_rule['actions'] << { 'id' => 9, 'action_type' => 'assign', 'field' => 'entities_id', 'value' => '5' }
      expect(resource_of('Staff rule')[:actions]).to include(
        { 'action_type' => 'assign', 'field' => 'entities_id', 'value' => 'Root entity > Customer A' },
      )
    end
  end

  describe 'insync?' do
    let(:is) { resource_of('Staff rule') }

    it 'actions in a different order are insync' do
      expect(is[:actions].map { |a| a['field'] }).to eq(['is_recursive', 'profiles_id'])
      expect(staff_should[:actions].map { |a| a['field'] }).to eq(['profiles_id', 'is_recursive'])
      expect(provider.insync?(context, 'Staff rule', :actions, is, staff_should)).to be true
      expect(provider.insync?(context, 'Staff rule', :actions, is, staff_should.merge(actions: staff_should[:actions].reverse))).to be true
    end

    it 'compares profile and entity values by id, whether given as name or id' do
      should = staff_should.merge(actions: [
                                    { 'action_type' => 'assign', 'field' => 'is_recursive', 'value' => '1' },
                                    { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => '6' },
                                  ])
      expect(provider.insync?(context, 'Staff rule', :actions, is, should)).to be true
    end

    it 'reports different actions as out of sync' do
      should = staff_should.merge(actions: [{ 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Admin' }])
      expect(provider.insync?(context, 'Staff rule', :actions, is, should)).to be false
    end

    it 'criteria in a different order are insync, a changed pattern is not' do
      staff_rule['criteria'] << { 'id' => 6, 'criteria' => 'email', 'condition' => 0, 'pattern' => 'x@example.com' }
      criteria = [{ 'criteria' => 'email', 'condition' => 0, 'pattern' => 'x@example.com' },
                  { 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'example-group' }]
      expect(provider.insync?(context, 'Staff rule', :criteria, is, staff_should.merge(criteria: criteria))).to be true
      criteria[1] = criteria[1].merge('pattern' => 'other-group')
      expect(provider.insync?(context, 'Staff rule', :criteria, is, staff_should.merge(criteria: criteria))).to be false
    end

    it 'fails the resource with a clear error for an unknown profile name' do
      should = staff_should.merge(actions: [{ 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Nope' }])
      expect { provider.insync?(context, 'Staff rule', :actions, is, should) }
        .to raise_error(Puppet::ResourceError, %r{unknown profile 'Nope'})
    end

    it 'leaves the other attributes to the default comparison' do
      expect(provider.insync?(context, 'Staff rule', :match, is, staff_should)).to be_nil
    end
  end

  describe 'create' do
    let(:new_should) do
      staff_should.merge(name: 'New rule', is_active: false)
    end

    before(:each) do
      allow(transport).to receive(:post).with(context, right_path, anything) do |_c, _p, body|
        collections[right_path] << body.merge('id' => 30, 'ranking' => 5, 'criteria' => [], 'actions' => [])
        { 'id' => 30, 'href' => "#{right_path}/30" }
      end
      allow(transport).to receive(:post).with(context, "#{right_path}/30/Action", anything) do |_c, _p, body|
        collections[right_path].last['actions'] << body.merge('id' => 40 + collections[right_path].last['actions'].size)
        { 'id' => 40 }
      end
      allow(transport).to receive(:post).with(context, "#{right_path}/30/Criteria", anything) do |_c, _p, body|
        collections[right_path].last['criteria'] << body.merge('id' => 50)
        { 'id' => 50 }
      end
    end

    it 'posts a new rule to its collection with entity 0, recursive, condition 0 and the marker' do
      provider.create(context, 'New rule', new_should)
      expect(transport).to have_received(:post).with(
        context, right_path,
        { 'name' => 'New rule', 'match' => 'AND', 'is_active' => false, 'entity' => 0,
          'is_recursive' => true, 'condition' => 0, 'comment' => marker }
      )
      expect(transport).to have_received(:post).with(
        context, "#{right_path}/30/Criteria", { 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'example-group' }
      )
    end

    it 'profiles_id value "Technician" resolves to its id on write and reads back as "Technician"' do
      provider.create(context, 'New rule', new_should)
      expect(transport).to have_received(:post).with(
        context, "#{right_path}/30/Action", { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => '6' }
      )
      expect(resource_of('New rule')[:actions]).to include(
        { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Technician' },
      )
    end

    it 'an existing unmarked rule of the same name is updated, not duplicated, and gains the marker' do
      expect(provider.get(context, ['Hand made'])).to eq([])

      provider.create(context, 'Hand made', staff_should.merge(name: 'Hand made'))

      expect(transport).not_to have_received(:post).with(context, right_path, anything)
      expect(transport).to have_received(:patch).with(
        context, "#{right_path}/11",
        { 'name' => 'Hand made', 'match' => 'AND', 'is_active' => true, 'comment' => "made by hand\n#{marker}" }
      )
      expect(transport).to have_received(:delete).with(context, "#{right_path}/11/Criteria/4")
      expect(transport).to have_received(:delete).with(context, "#{right_path}/11/Action/5")
      expect(transport).to have_received(:post).with(context, "#{right_path}/11/Action",
                                                     { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => '6' })
    end

    it 'adds the marker only once' do
      hand_made['comment'] = "made by hand\n#{marker}"
      provider.update(context, 'Hand made', staff_should.merge(name: 'Hand made'))
      expect(transport).to have_received(:patch).with(
        context, "#{right_path}/11", { 'name' => 'Hand made', 'match' => 'AND', 'is_active' => true }
      )
    end
  end

  describe 'update' do
    it 'replaces all criteria when they differ and leaves equal actions alone' do
      should = staff_should.merge(criteria: [{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'other-group' }])
      provider.update(context, 'Staff rule', should)
      expect(transport).to have_received(:post).with(
        context, "#{right_path}/10/Criteria", { 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'other-group' }
      ).ordered
      expect(transport).to have_received(:delete).with(context, "#{right_path}/10/Criteria/1").ordered
      expect(transport).not_to have_received(:delete).with(context, %r{/Action/})
      expect(transport).not_to have_received(:post).with(context, %r{/Action\z}, anything)
    end

    it 'replaces all actions when they differ (old ones removed first)' do
      should = staff_should.merge(actions: [{ 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Admin' }])
      provider.update(context, 'Staff rule', should)
      expect(transport).to have_received(:delete).with(context, "#{right_path}/10/Action/2").ordered
      expect(transport).to have_received(:delete).with(context, "#{right_path}/10/Action/3").ordered
      expect(transport).to have_received(:post).with(
        context, "#{right_path}/10/Action", { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => '3' }
      ).ordered
    end

    it 'refuses to move a rule to another collection' do
      expect { provider.update(context, 'Staff rule', staff_should.merge(collection: 'import_asset')) }
        .to raise_error(Puppet::ResourceError, %r{collection right.*cannot be moved}m)
    end
  end

  describe 'before_rule' do
    let(:lamp_should) do
      {
        name: 'Ignore lamps', ensure: 'present', collection: 'import_asset', match: 'AND', is_active: true,
        criteria: [{ 'criteria' => 'name', 'condition' => 6, 'pattern' => '/Lamp$/' }],
        actions: [{ 'action_type' => 'assign', 'field' => '_ignore_import', 'value' => '1' }],
        before_rule: 'Device update'
      }
    end

    it 'finds the before_rule target case-insensitively' do
      provider.update(context, 'Ignore lamps', lamp_should.merge(before_rule: 'DEVICE update'))
      expect(transport).to have_received(:patch).with(context, "#{import_path}/21", { 'ranking' => 36 })
    end

    it 'before places the rule above the named rule' do
      is = resource_of('Ignore lamps')
      expect(provider.insync?(context, 'Ignore lamps', :before_rule, is, lamp_should)).to be false

      provider.update(context, 'Ignore lamps', lamp_should)
      expect(transport).to have_received(:patch).with(context, "#{import_path}/21", { 'ranking' => 36 })
    end

    it 'is in sync when the rule already ranks above the named rule' do
      lamp_rule['ranking'] = 35
      is = resource_of('Ignore lamps')
      expect(provider.insync?(context, 'Ignore lamps', :before_rule, is, lamp_should)).to be true

      provider.update(context, 'Ignore lamps', lamp_should)
      expect(transport).not_to have_received(:patch).with(context, anything, hash_including('ranking'))
    end

    it 'fails clearly when the named rule does not exist in the collection' do
      is = resource_of('Ignore lamps')
      expect { provider.insync?(context, 'Ignore lamps', :before_rule, is, lamp_should.merge(before_rule: 'Staff rule')) }
        .to raise_error(Puppet::ResourceError, %r{no rule 'Staff rule' in collection import_asset})
    end
  end

  describe 'delete' do
    it 'deletes a marked rule through its own collection path' do
      provider.plan_deletions(:run, ['Ignore lamps'])
      provider.set(context, 'Ignore lamps' => { is: resource_of('Ignore lamps'), should: { name: 'Ignore lamps', ensure: 'absent' } })
      expect(transport).to have_received(:delete).with(context, "#{import_path}/21")
    end
  end

  describe 'write-through' do
    it 'reads the list whole for before_rule when the re-read after a children change failed' do
      allow(transport).to receive(:get).and_raise(Puppet::ResourceError, 'GLPI API error 500')
      lamp_should = {
        name: 'Ignore lamps', ensure: 'present', collection: 'import_asset', match: 'AND', is_active: true,
        criteria: [{ 'criteria' => 'name', 'condition' => 6, 'pattern' => '/Bulb$/' }], before_rule: 'Device update'
      }
      expect { provider.update(context, 'Ignore lamps', lamp_should) }.not_to raise_error
      expect(transport).to have_received(:patch).with(context, "#{import_path}/21", { 'ranking' => 36 })
    end

    it 'updates rules reading each collection once, re-reading only the written rule' do
      provider.update(context, 'Staff rule', staff_should.merge(criteria: [{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'other-group' }]))
      provider.update(context, 'Hand made', staff_should.merge(name: 'Hand made'))
      collections.each_key { |p| expect(transport).to have_received(:get_all).with(context, p, anything).once }
      expect(transport).to have_received(:get).with(context, "#{right_path}/10").twice
      expect(transport).to have_received(:get).with(context, "#{right_path}/11").twice
    end

    it 'reads the whole list again after a ranking move (GLPI shifts the other rules)' do
      lamp_should = { name: 'Ignore lamps', ensure: 'present', collection: 'import_asset', before_rule: 'Device update' }
      provider.update(context, 'Ignore lamps', lamp_should)
      resource_of('Device update')
      expect(transport).to have_received(:get_all).with(context, import_path, anything).twice
    end

    it 'reads the whole list again after a delete (GLPI renumbers the rankings)' do
      provider.plan_deletions(:run, ['Ignore lamps'])
      provider.set(context, 'Ignore lamps' => { is: resource_of('Ignore lamps'), should: { name: 'Ignore lamps', ensure: 'absent' } })
      resource_of('Device update')
      expect(transport).to have_received(:get_all).with(context, import_path, anything).twice
    end

    it 'does not cache a re-read rule without its criteria and actions' do
      allow(transport).to receive(:get) { |_c, _p, _q = nil| staff_rule.except('criteria', 'actions') }
      provider.update(context, 'Staff rule', staff_should)
      expect(resource_of('Staff rule')[:criteria]).to eq([{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'example-group' }])
      expect(transport).to have_received(:get_all).with(context, right_path, anything).twice
    end

    it 'shares the profile list with the other glpi_* providers' do
      resource_of('Staff rule')
      described_class.new.get(context, ['Staff rule'])
      expect(transport).to have_received(:get_all).with(context, '/Administration/Profile', anything).once
    end
  end

  describe 'a failure after the body was written' do
    it 'drops the rule list, so the next use reads it whole' do
      allow(transport).to receive(:post).and_raise(Puppet::ResourceError, 'GLPI said no')
      provider.get(context, ['Staff rule'])
      wanted = { name: 'Staff rule', ensure: 'present', collection: 'right', match: 'AND', is_active: true, criteria: [], actions: [] }
      wanted[:criteria] = [{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'other-group' }]
      expect { provider.update(context, 'Staff rule', wanted) }.to raise_error(Puppet::ResourceError, 'GLPI said no')
      expect(provider.instance_variable_get(:@objects)).to be_nil
    end

    it 'fails on an action naming a profile twice, with the ids' do
      profiles << { 'id' => 7, 'name' => 'admin' }
      provider.get(context, ['Staff rule'])
      wanted = { name: 'Staff rule', collection: 'right', actions: [{ 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Admin' }] }
      expect { provider.resource_to_api(context, wanted, nil) }.to raise_error(Puppet::ResourceError, %r{2 profile objects match 'Admin' \(ids 3, 7\)})
    end
  end
end
# rubocop:enable RSpec/MessageSpies
