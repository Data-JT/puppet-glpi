# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../lib/puppet/type/glpi_cluster'
require_relative '../../../../lib/puppet/type/glpi_appliance'
require_relative '../../../../lib/puppet/type/glpi_custom_asset'
require_relative '../../../../lib/puppet/provider/glpi_cluster/glpi_cluster'
require_relative '../../../../lib/puppet/provider/glpi_appliance/glpi_appliance'
require_relative '../../../../lib/puppet/provider/glpi_custom_asset/glpi_custom_asset'

# Whole agent runs through Puppet's own transaction, with
# `resources { purge => true }`: only here do the type hooks, the deletion plan
# and the guard meet the Resource API.
#
# Resource API 2.x (OpenVox 9) differs from 1.x in what this rests on: the
# purge listing fills a per-provider get cache, and a declared resource found
# in it gets its state from there, without refresh_current_state and so
# without the hooks that declare member types and fields. The results must be
# the same on both.
RSpec.describe 'an agent run with resources { purge => true }' do
  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-purge-run-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    { 'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet', 'client_secret' => 'not-a-real-secret',
      'username' => 'svc', 'password' => 'not-a-real-password', 'marker' => marker }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:writes) { [] }
  let(:collections) { {} }
  let(:providers) do
    [Puppet::Provider::GlpiCluster::GlpiCluster, Puppet::Provider::GlpiAppliance::GlpiAppliance, Puppet::Provider::GlpiCustomAsset::GlpiCustomAsset]
  end

  def object(id, name, comment, extra = {})
    { 'id' => id, 'name' => name, 'comment' => comment, 'is_deleted' => false, 'type' => nil }.merge(extra)
  end

  def fresh_type(type_name)
    type = Puppet::Type.type(type_name)
    # A new agent run: a new provider and an empty get cache.
    [:@my_provider, :@rsapi_provider_get_cache].each { |ivar| type.instance_variable_set(ivar, nil) }
    type
  end

  # Applies +declared+ ([type, title, parameters]) and a purge of +purged+;
  # returns the transaction's report.
  def apply(purged, declared)
    fresh_type(purged)
    catalog = Puppet::Resource::Catalog.new
    declared.each { |type, title, parameters| catalog.add_resource(Puppet::Resource.new(type, title, parameters: parameters)) }
    catalog.add_resource(Puppet::Resource.new(:resources, purged.to_s, parameters: { purge: true }))
    catalog.to_ral.apply.report
  end

  def failed_titles(report)
    report.resource_statuses.values.select(&:failed).map(&:resource)
  end

  before(:each) do
    File.write(config_file, config.to_yaml)
    Puppet[:statedir] = config_dir
    Puppet[:transactionstorefile] = File.join(config_dir, 'transactionstore.yaml')
    providers.each { |provider| allow(provider).to receive_messages(config_path: config_file, build_transport: transport) }
    copy = ->(value) { Marshal.load(Marshal.dump(value)) }
    allow(transport).to receive(:get_all) { |_ctx, path, _query| copy.call(collections.fetch(path)) }
    allow(transport).to receive(:get) do |_ctx, path, _query = nil|
      next copy.call(collections.fetch(path)) if collections.key?(path)

      collection, id = path.match(%r{\A(.+)/(\d+)\z}).captures
      copy.call(collections.fetch(collection).find { |entry| entry['id'].to_s == id })
    end
    allow(transport).to receive(:patch) { |_ctx, path, body| writes << [:patch, path, body] }
    allow(transport).to receive(:post) do |_ctx, path, body|
      writes << [:post, path, body]
      { 'id' => 99 }
    end
    allow(transport).to receive(:delete) { |_ctx, path, _query = nil| writes << [:delete, path] }
    allow(transport).to receive(:close)
  end

  # The types are process-wide: leave no provider or get cache behind.
  after(:each) do
    [:glpi_cluster, :glpi_appliance, :glpi_custom_asset].each { |type_name| fresh_type(type_name) }
    FileUtils.remove_entry(config_dir)
  end

  context 'with one undeclared marked cluster' do
    let(:collections) do
      { '/Management/Cluster' => [object(1, 'Kept', marker), object(2, 'Stale', marker), object(3, 'Spare', marker), object(4, 'Lab', 'by hand')],
        '/Dropdowns/ClusterType' => [] }
    end
    let(:declared) { [[:glpi_cluster, 'Kept', {}], [:glpi_cluster, 'Spare', {}], [:glpi_cluster, 'Lab', { comment: 'mine now' }]] }

    it 'trashes it and writes nothing else, the unmarked cluster included' do
      apply(:glpi_cluster, declared)
      expect(writes).to eq([[:delete, '/Management/Cluster/2']])
    end

    it 'does not purge a marked cluster declared in another case' do
      apply(:glpi_cluster, [[:glpi_cluster, 'kept', {}], [:glpi_cluster, 'STALE', {}], [:glpi_cluster, 'SPARE', {}]])
      expect(writes).to be_empty
    end

    it 'never purges an unmarked cluster' do
      apply(:glpi_cluster, [[:glpi_cluster, 'Kept', {}], [:glpi_cluster, 'Spare', {}], [:glpi_cluster, 'Stale', {}]])
      expect(writes).to be_empty
    end
  end

  context 'with more undeclared marked clusters than the guard allows' do
    let(:collections) do
      { '/Management/Cluster' => (1..8).map { |id| object(id, "Cluster #{id}", marker) }, '/Dropdowns/ClusterType' => [] }
    end

    it 'fails every deletion of the type and deletes nothing' do
      report = apply(:glpi_cluster, [[:glpi_cluster, 'Cluster 1', {}]])
      expect(writes).to be_empty
      expect(failed_titles(report).size).to eq(7)
    end
  end

  context 'with a declared appliance the purge listing also returns' do
    let(:collections) do
      {
        '/Assets/Appliance' => [object(1, 'Web shop', marker, 'environment' => nil)],
        '/Assets/Computer' => [{ 'id' => 10, 'name' => 'web1', 'is_deleted' => false }],
        '/Assets/Monitor' => [{ 'id' => 7, 'name' => 'Screen', 'is_deleted' => false }],
      }
    end

    before(:each) do
      allow(transport).to receive(:graphql_all).and_return(
        [{ 'id' => 100, 'itemtype' => 'Computer', 'items_id' => 10, 'appliance' => { 'id' => 1 } },
         { 'id' => 101, 'itemtype' => 'Monitor', 'items_id' => 7, 'appliance' => { 'id' => 1 } }],
      )
    end

    it 'leaves the links of itemtypes outside member_types alone' do
      report = apply(:glpi_appliance, [[:glpi_appliance, 'Web shop', { members: [{ 'itemtype' => 'Computer', 'name' => 'web1' }] }]])
      expect(failed_titles(report)).to be_empty
      expect(writes).to be_empty
    end
  end

  context 'with a declared custom asset the purge listing also returns' do
    let(:collections) do
      {
        '/Assets/Custom/' => [{ 'itemtype' => 'Website', 'name' => 'Website', 'href' => '/Assets/Custom/Website' }],
        '/Assets/Custom/Website' => [
          object(1, 'www', marker, 'entity' => { 'id' => 0, 'name' => 'Root entity' }, 'custom_fields' => { 'url' => 'x', 'other' => 'by hand' }),
        ],
        '/Administration/Entity' => [{ 'id' => 0, 'name' => 'Root entity', 'tag' => '', 'parent' => nil }],
      }
    end

    it 'compares only the declared fields' do
      report = apply(:glpi_custom_asset, [[:glpi_custom_asset, 'Website/www', { fields: { 'url' => 'x' } }]])
      expect(failed_titles(report)).to be_empty
      expect(writes).to be_empty
    end
  end
end
