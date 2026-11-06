# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../../lib/puppet/provider/glpi_cluster/glpi_cluster'

# rubocop:disable RSpec/MessageSpies
RSpec.describe Puppet::Provider::GlpiCluster::GlpiCluster do
  subject(:provider) { described_class.new }

  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-cluster-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password',
      'marker' => marker, 'purge_max_fraction' => 0.5
    }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:type) { instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_cluster', namevars: [:name], ensurable?: true) }
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }
  let(:path) { '/Management/Cluster' }

  let(:cluster) do
    { 'id' => 1, 'name' => 'Cluster A', 'comment' => "#{marker}\nThree nodes", 'is_deleted' => false, 'type' => { 'id' => 4, 'name' => 'Hypervisor' } }
  end
  let(:untyped) { { 'id' => 2, 'name' => 'Cluster B', 'comment' => marker, 'is_deleted' => false, 'type' => nil } }
  let(:handmade) { { 'id' => 3, 'name' => 'Lab', 'comment' => 'by hand', 'is_deleted' => false, 'type' => nil } }
  let(:trashed) { { 'id' => 4, 'name' => 'Retired', 'comment' => marker, 'is_deleted' => true, 'type' => nil } }
  let(:clusters) { [cluster, untyped, handmade, trashed] }
  let(:cluster_types) { [{ 'id' => 4, 'name' => 'Hypervisor' }] }

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(described_class).to receive_messages(config_path: config_file, build_transport: transport)
    lists = { path => -> { clusters }, '/Dropdowns/ClusterType' => -> { cluster_types } }
    allow(transport).to receive(:get_all) { |_ctx, p, _q| Marshal.load(Marshal.dump(lists.fetch(p).call)) }
    allow(transport).to receive(:get) do |_ctx, p, _q = nil|
      collection, id = p.match(%r{\A(.+)/(\d+)\z}).captures
      Marshal.load(Marshal.dump(lists.fetch(collection).call.find { |o| o['id'].to_s == id }))
    end
    # A created object is stored, so the read-back after the POST finds it.
    allow(transport).to receive(:post) do |_ctx, p, body|
      lists[p]&.call&.push(body.merge('id' => 9, 'is_deleted' => false))
      { 'id' => 9 }
    end
    allow(transport).to receive(:patch)
    allow(transport).to receive(:delete)
    allow(type).to receive(:feature?).and_return(false)
    allow(type).to receive(:feature?).with('simple_get_filter').and_return(true)
    [:debug, :info, :notice, :warning, :err].each { |level| allow(context).to receive(level) }
  end

  after(:each) { FileUtils.remove_entry(config_dir) }

  def should_for(name, overrides = {})
    { name: name, ensure: 'present' }.merge(overrides)
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_cluster/glpi_cluster.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  describe 'get' do
    it 'maps the cluster type by name and the comment without the marker' do
      expect(provider.get(context, ['Cluster A', 'Cluster B'])).to eq(
        [
          { name: 'Cluster A', ensure: 'present', cluster_type: 'Hypervisor', comment: 'Three nodes' },
          { name: 'Cluster B', ensure: 'present', cluster_type: '', comment: '' },
        ],
      )
    end

    it 'lists only marked, non-trashed clusters for purge' do
      expect(provider.get(context, []).map { |r| r[:name] }).to eq(['Cluster A', 'Cluster B'])
      expect(provider.get(context, ['Retired'])).to eq([])
    end
  end

  describe 'insync?' do
    it 'unmarked same-name cluster: warning, no change' do
      is = provider.get(context, ['Lab']).first
      expect(provider.insync?(context, 'Lab', :comment, is, should_for('Lab', comment: 'other'))).to be true
      provider.update(context, 'Lab', should_for('Lab', comment: 'other'))
      expect(context).to have_received(:warning).with(%r{'Lab' left unchanged}).at_least(:once)
      expect(transport).not_to have_received(:patch)
    end

    it 'matches a cluster whose name differs only in case, and compares its type that way too' do
      is = provider.get(context, ['CLUSTER a']).first
      expect(is).to include(name: 'CLUSTER a', cluster_type: 'Hypervisor')
      expect(provider.insync?(context, 'CLUSTER a', :cluster_type, is, should_for('CLUSTER a', cluster_type: 'hypervisor'))).to be true
      expect(provider.insync?(context, 'CLUSTER a', :comment, is, should_for('CLUSTER a', comment: 'three nodes'))).to be false
    end

    it 'adopts nothing and creates nothing for a case-variant of an existing cluster' do
      provider.create(context, 'cluster a', should_for('cluster a', cluster_type: 'HYPERVISOR'))
      expect(transport).not_to have_received(:post)
      expect(transport).to have_received(:patch).with(context, "#{path}/1", hash_including('type' => 4))
    end

    it 'compares the type by name, normalized' do
      is = provider.get(context, ['Cluster A']).first
      expect(provider.insync?(context, 'Cluster A', :cluster_type, is, should_for('Cluster A', cluster_type: 'Hypervisor '))).to be true
      expect(provider.insync?(context, 'Cluster A', :cluster_type, is, should_for('Cluster A', cluster_type: 'Storage'))).to be false
    end
  end

  describe 'create' do
    it 'POSTs entity 0, recursive, the marker-first comment and the type id' do
      provider.create(context, 'Cluster C', should_for('Cluster C', comment: 'New', cluster_type: 'Hypervisor'))
      expect(transport).to have_received(:post).with(
        context, path, { 'name' => 'Cluster C', 'comment' => "#{marker}\nNew", 'type' => 4, 'entity' => 0, 'is_recursive' => true }
      )
    end

    it 'creates a missing cluster type by name' do
      provider.create(context, 'Cluster C', should_for('Cluster C', cluster_type: 'Storage'))
      expect(transport).to have_received(:post).with(context, '/Dropdowns/ClusterType', { 'name' => 'Storage', 'entity' => 0, 'is_recursive' => true })
      expect(transport).to have_received(:post).with(context, path, hash_including('type' => 9))
    end

    it 'writes just the marker when there is no comment' do
      provider.create(context, 'Cluster C', should_for('Cluster C'))
      expect(transport).to have_received(:post).with(context, path, { 'name' => 'Cluster C', 'comment' => marker, 'entity' => 0, 'is_recursive' => true })
    end

    it 'does not restore a trashed same-name cluster' do
      provider.create(context, 'Retired', should_for('Retired'))
      expect(transport).to have_received(:post).with(context, path, hash_including('name' => 'Retired'))
      expect(context).to have_received(:warning).with(%r{trashed.*'Retired'})
    end
  end

  describe 'update' do
    it 'PATCHes the comment and an empty type as none' do
      provider.update(context, 'Cluster A', should_for('Cluster A', comment: 'Two nodes', cluster_type: ''))
      expect(transport).to have_received(:patch).with(context, "#{path}/1", { 'comment' => "#{marker}\nTwo nodes", 'type' => 0 })
    end
  end

  describe 'write-through' do
    it 'creates a missing cluster type once for several clusters (the shared list learns it)' do
      allow(transport).to receive(:post).with(context, '/Dropdowns/ClusterType', anything) do |_c, _p, body|
        cluster_types << body.merge('id' => 8)
        { 'id' => 8 }
      end
      allow(transport).to receive(:post).with(context, path, anything) do |_c, _p, body|
        id = clusters.map { |c| c['id'] }.max + 1
        clusters << body.merge('id' => id, 'is_deleted' => false, 'type' => { 'id' => body['type'], 'name' => 'Storage' })
        { 'id' => id }
      end
      provider.plan_deletions(:run, [])
      provider.get(context, ['Cluster C'])
      provider.create(context, 'Cluster C', should_for('Cluster C', cluster_type: 'Storage'))
      provider.create(context, 'Cluster D', should_for('Cluster D', cluster_type: 'Storage'))
      expect(transport).to have_received(:post).with(context, '/Dropdowns/ClusterType', anything).once
      expect(transport).to have_received(:get_all).with(context, '/Dropdowns/ClusterType', anything).once
      expect(transport).to have_received(:get_all).with(context, path, anything).once
      expect(provider.get(context, ['Cluster C', 'Cluster D']).map { |r| r[:cluster_type] }).to eq(['Storage', 'Storage'])
    end
  end

  describe 'delete_properties' do
    let(:listed) { should_for('Cluster A', delete_properties: ['comment', 'cluster_type']) }

    before(:each) { provider.plan_deletions(:run, []) }

    it 'clears both through the empty value, keeping the marker' do
      provider.get(context, ['Cluster A'])
      provider.update(context, 'Cluster A', listed)
      expect(transport).to have_received(:patch).with(context, "#{path}/1", 'comment' => marker, 'type' => 0)
    end

    it 'is out of sync while either attribute is set, and in sync once both read back empty' do
      is = provider.get(context, ['Cluster A']).first
      expect(provider.insync?(context, 'Cluster A', :delete_properties, is, listed)).to be(false)
      expect(provider.insync?(context, 'Cluster A', :delete_properties, is.merge(comment: ''), listed)).to be(false)
      expect(provider.insync?(context, 'Cluster A', :delete_properties, is.merge(comment: '', cluster_type: ''), listed)).to be(true)
    end

    it 'refuses a value for an attribute that is also listed: it could never converge' do
      is = provider.get(context, ['Cluster A']).first
      expect { provider.insync?(context, 'Cluster A', :delete_properties, is, should_for('Cluster A', comment: 'x', delete_properties: ['comment'])) }
        .to raise_error(Puppet::ResourceError, %r{cannot set and delete the same properties: comment})
    end

    # insync? failing only fails that property: a change of another property
    # still reaches update, which must not write the half-applied resource.
    it 'writes nothing when a listed attribute also has a value' do
      should = should_for('Cluster A', comment: 'x', delete_properties: ['comment'])
      provider.get(context, ['Cluster A'])
      expect { provider.update(context, 'Cluster A', should) }.to raise_error(Puppet::ResourceError, %r{cannot set and delete the same properties: comment})
      expect { provider.create(context, 'Cluster A', should) }.to raise_error(Puppet::ResourceError, %r{cannot set and delete the same properties: comment})
      expect(transport).not_to have_received(:patch)
      expect(transport).not_to have_received(:post)
    end

    it 'is ignored on create' do
      provider.get(context, ['Cluster C'])
      provider.create(context, 'Cluster C', should_for('Cluster C', delete_properties: ['comment', 'cluster_type']))
      expect(transport).to have_received(:post).with(context, path, hash_excluding('type'))
    end

    # An unmarked cluster of a skip_unmarked type is never written.
    it 'reports an unmarked object in sync with a warning and never writes it' do
      is = provider.get(context, ['Lab']).first
      listed = should_for('Lab', delete_properties: ['comment'])
      expect(provider.insync?(context, 'Lab', :delete_properties, is, listed)).to be(true)
      expect(context).to have_received(:warning).with(%r{Lab.*left unchanged})
      provider.update(context, 'Lab', listed)
      provider.create(context, 'Lab', listed)
      expect(transport).not_to have_received(:patch)
    end

    it 'does not get in the way of a removal' do
      is = provider.get(context, ['Cluster A']).first
      absent = should_for('Cluster A', ensure: 'absent', delete_properties: ['comment'])
      expect(provider.insync?(context, 'Cluster A', :delete_properties, is, absent)).to be(true)
    end

    it 'leaves a catalog without it exactly as before: the stored comment is resent, the type is not touched' do
      provider.get(context, ['Cluster A'])
      provider.update(context, 'Cluster A', should_for('Cluster A'))
      expect(transport).to have_received(:patch).with(context, "#{path}/1", 'comment' => "#{marker}\nThree nodes")
    end
  end

  describe 'dropdown values' do
    let(:cluster_types) { [{ 'id' => 4, 'name' => 'Hypervisor' }, { 'id' => 5, 'name' => 'hypervisor' }] }

    it 'fails on a duplicated value, with the ids' do
      provider.get(context, ['Cluster A'])
      expect { provider.update(context, 'Cluster A', should_for('Cluster A', cluster_type: 'HYPERVISOR')) }
        .to raise_error(Puppet::ResourceError, %r{2 values named 'HYPERVISOR'.*ids 4, 5})
      expect(transport).not_to have_received(:patch)
    end

    it 'fails when GLPI answers a new value without an id, and reads the list again' do
      allow(transport).to receive(:post).with(context, '/Dropdowns/ClusterType', anything).and_return({})
      provider.get(context, ['Cluster A'])
      expect { provider.update(context, 'Cluster A', should_for('Cluster A', cluster_type: 'Storage')) }
        .to raise_error(Puppet::ResourceError, %r{returned no id})
      expect(transport).not_to have_received(:patch)
    end
  end
end
# rubocop:enable RSpec/MessageSpies
