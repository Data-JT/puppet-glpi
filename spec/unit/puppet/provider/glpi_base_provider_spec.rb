# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../lib/puppet/provider/glpi_base_provider'

# @api private
module Puppet::Provider::GlpiThing; end

# Minimal provider plugging into the base: one collection, `name` as natural
# key, a user-visible comment with the marker stripped on read.
class Puppet::Provider::GlpiThing::GlpiThing < Puppet::Provider::GlpiBaseProvider
  def collection_path
    '/Test/Thing'
  end

  def api_to_resource(_context, object)
    { name: PuppetX::Glpi::Names.normalize(object['name']), comment: strip_marker(object['comment']) }
  end

  def resource_to_api(_context, should, _existing)
    { 'name' => should[:name], 'comment' => should[:comment] }.compact
  end
end

# Same, without a comment attribute (marker appended to the existing comment).
class Puppet::Provider::GlpiThing::Plain < Puppet::Provider::GlpiThing::GlpiThing
  def self.glpi_type_name
    'glpi_thing'
  end

  def api_to_resource(_context, object)
    { name: PuppetX::Glpi::Names.normalize(object['name']) }
  end

  def resource_to_api(_context, should, _existing)
    { 'name' => should[:name] }
  end
end

# Same, with a guard scope: the prefix of the name before a dash.
class Puppet::Provider::GlpiThing::Scoped < Puppet::Provider::GlpiThing::GlpiThing
  def self.glpi_type_name
    'glpi_thing'
  end

  def guard_scope(key_or_object)
    key = (key_or_object.is_a?(Hash) && key_or_object.key?('name')) ? key_or_object['name'] : resource_key(key_or_object)
    key.to_s.split('-').first
  end
end

# Writes only what differs: nothing for an existing object.
class Puppet::Provider::GlpiThing::Quiet < Puppet::Provider::GlpiThing::Plain
  def resource_to_api(_context, should, existing)
    existing ? {} : { 'name' => should[:name] }
  end
end

# Composite identity (kind, name) whose guard_scope reads only a raw object
# (string keys): a title (Hash with symbol keys) yields '' here, so the guard
# must take the scope from the live object a pending title names.
class Puppet::Provider::GlpiThing::Composite < Puppet::Provider::GlpiThing::GlpiThing
  def self.glpi_type_name
    'glpi_thing'
  end

  def object_key(object)
    "#{object['kind']}/#{object['name']}"
  end

  def resource_key(name)
    name.is_a?(Hash) ? "#{name[:kind]}/#{name[:name]}" : name
  end

  def guard_scope(key_or_object)
    key_or_object.is_a?(Hash) ? key_or_object['kind'].to_s : ''
  end
end

RSpec.describe Puppet::Provider::GlpiBaseProvider do
  subject(:provider) { provider_class.new }

  let(:provider_class) { Puppet::Provider::GlpiThing::GlpiThing }
  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-base-provider-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url'           => 'https://glpi.example.com/api.php',
      'client_id'          => 'puppet',
      'client_secret'      => 'not-a-real-secret',
      'username'           => 'svc',
      'password'           => 'not-a-real-password',
      'grant_type'         => 'password',
      'ssl_verify'         => true,
      'marker'             => marker,
      'type_markers'       => { 'glpi_other' => '[other marker]' },
      'purge_max_fraction' => 0.5,
    }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:type) do
    instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_thing', namevars: [:name], ensurable?: true)
  end
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }
  let(:objects) { [] }

  def obj(id, name, comment = '')
    { 'id' => id, 'name' => name, 'comment' => comment }
  end

  # GLPI's answer to a POST: the object is stored and readable by id.
  def store_post(_ctx, _path, body)
    id = (objects.map { |o| o['id'] }.max || 0) + 100
    objects << body.merge('id' => id)
    { 'id' => id, 'href' => "/Test/Thing/#{id}" }
  end

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(provider_class).to receive_messages(config_path: config_file, build_transport: transport)
    allow(transport).to receive(:get_all).with(context, '/Test/Thing', anything) { objects }
    allow(transport).to receive(:get) { |_ctx, p, _q = nil| objects.find { |o| "/Test/Thing/#{o['id']}" == p }&.dup }
    allow(transport).to receive(:post) { |*args| store_post(*args) }
    allow(type).to receive(:feature?).and_return(false)
    allow(type).to receive(:feature?).with('simple_get_filter').and_return(true)
    allow(type).to receive(:check_schema)
    [:debug, :info, :notice, :warning].each { |level| allow(context).to receive(level) }
    [:creating, :updating, :deleting].each { |action| allow(context).to receive(action).and_yield }
  end

  after(:each) { FileUtils.remove_entry(config_dir) }

  describe 'unresolved references' do
    it "defaults to 'warn', also without the transport file" do
      expect(provider.module_settings[:unresolved]).to eq('warn')
      expect(provider.fail_unresolved?).to be false
      File.delete(config_file)
      expect(provider.fail_unresolved?).to be false
    end

    it "reads 'fail' from the transport file" do
      File.write(config_file, config.merge('unresolved' => 'fail').to_yaml)
      expect(provider.fail_unresolved?).to be true
    end

    it 'raise_unresolved raises the messages once per target state' do
      should = { name: 'a' }
      expect { provider.raise_unresolved(should, ['one', 'two']) }.to raise_error(Puppet::ResourceError, 'one; two')
      expect(provider.unresolved_reported?(should)).to be true
      expect { provider.raise_unresolved(should, ['one']) }.not_to raise_error
      expect(provider.unresolved_reported?({ name: 'a' })).to be false
      expect { provider.raise_unresolved({ name: 'a' }, ['one']) }.to raise_error(Puppet::ResourceError)
      expect { provider.raise_unresolved({ name: 'b' }, []) }.not_to raise_error
    end
  end

  describe 'markers' do
    it 'uses the configured marker, or the per-type override' do
      expect(provider.marker_for('glpi_thing')).to eq(marker)
      expect(provider.marker_for('glpi_other')).to eq('[other marker]')
    end

    it 'falls back to the default marker when the transport file is missing' do
      File.delete(config_file)
      expect(provider.marker_for('glpi_thing')).to eq('[managed by puppet]')
    end

    it 'managed? is true only when the comment contains the type marker' do
      expect(provider.managed?("note\n#{marker}", 'glpi_thing')).to be true
      expect(provider.managed?('note', 'glpi_thing')).to be false
      expect(provider.managed?(nil, 'glpi_thing')).to be false
      expect(provider.managed?(marker, 'glpi_other')).to be false
    end

    it 'with_marker puts the type marker first, exactly once (idempotent)' do
      once = provider.with_marker('Customer A cluster', 'glpi_thing')
      expect(once).to eq("#{marker}\nCustomer A cluster")
      expect(provider.with_marker(once, 'glpi_thing')).to eq(once)
      expect(provider.with_marker(nil, 'glpi_thing')).to eq(marker)
      expect(provider.with_marker('', 'glpi_thing')).to eq(marker)
    end

    it 'strip_marker removes the marker and its newline' do
      expect(provider.strip_marker("#{marker}\nCustomer A cluster", 'glpi_thing')).to eq('Customer A cluster')
      expect(provider.strip_marker("note\n#{marker}", 'glpi_thing')).to eq('note')
      expect(provider.strip_marker(marker, 'glpi_thing')).to eq('')
      expect(provider.strip_marker('A &#38; B', 'glpi_thing')).to eq('A & B')
    end

    it 'append_marker keeps the human comment and appends the marker once (idempotent)' do
      once = provider.append_marker("Created by hand\n", 'glpi_thing')
      expect(once).to eq("Created by hand\n#{marker}")
      expect(provider.append_marker(once, 'glpi_thing')).to eq(once)
      expect(provider.append_marker(nil, 'glpi_thing')).to eq(marker)
    end
  end

  describe '#find_unique' do
    it 'raises on two objects whose names normalize equal' do
      dupes = [obj(1, 'Customer A GmbH &#38; Co. KG'), obj(2, 'Customer A GmbH & Co. KG ')]
      expect { provider.find_unique(dupes, 'Customer A GmbH & Co. KG') }
        .to raise_error(Puppet::ResourceError, %r{glpi_thing.*Customer A GmbH & Co\. KG.*ids 1, 2})
    end

    it 'returns the single match, compared normalized' do
      expect(provider.find_unique([obj(1, 'A &#38; B'), obj(2, 'C')], 'A & B')['id']).to eq(1)
    end

    it 'returns nil when nothing matches' do
      expect(provider.find_unique([obj(1, 'A')], 'B')).to be_nil
    end
  end

  describe 'same-key duplicates' do
    let(:objects) { [obj(1, 'example.com', 'added by the inventory'), obj(2, 'Example.com', "#{marker}\nours")] }

    it 'find_unique returns the one marked object among same-key duplicates' do
      expect(context).to receive(:info).with(%r{glpi_thing.*'example\.com'.*unmarked.*id 1}).once
      expect(provider.find_unique(objects, 'example.com', context)['id']).to eq(2)
      expect(provider.find_unique(objects, 'example.com', context)['id']).to eq(2)
    end

    it 'find_unique raises when none of the duplicates is marked' do
      dupes = [obj(1, 'example.com'), obj(2, 'example.com', 'by hand')]
      expect { provider.find_unique(dupes, 'example.com', context) }
        .to raise_error(Puppet::ResourceError, %r{2 GLPI objects match the key 'example\.com' \(ids 1, 2\)})
    end

    it 'find_unique raises when two duplicates are marked' do
      dupes = [obj(1, 'example.com', marker), obj(2, 'example.com', marker), obj(3, 'example.com')]
      expect { provider.find_unique(dupes, 'example.com', context) }
        .to raise_error(Puppet::ResourceError, %r{3 GLPI objects match the key 'example\.com' \(ids 1, 2, 3\)})
    end

    it 'match_only types still raise on duplicates' do
      allow(provider).to receive(:adoption_policy).and_return(:match_only)
      expect { provider.find_unique(objects, 'example.com', context) }
        .to raise_error(Puppet::ResourceError, %r{ids 1, 2})
      expect { provider.update(context, 'example.com', name: 'example.com', comment: 'x', ensure: 'present') }
        .to raise_error(Puppet::ResourceError, %r{ids 1, 2})
    end

    it 'get with names reports the marked object' do
      expect(provider.get(context, ['example.com'])).to eq([{ name: 'example.com', comment: 'ours', ensure: 'present' }])
    end

    it 'create/update on a key with a marked + an unmarked twin writes only the marked object' do
      expect(transport).not_to receive(:post)
      expect(transport).not_to receive(:patch).with(context, '/Test/Thing/1', anything)
      expect(transport).to receive(:patch).with(context, '/Test/Thing/2', { 'name' => 'example.com', 'comment' => "#{marker}\nnew" }).twice
      provider.create(context, 'example.com', name: 'example.com', comment: 'new', ensure: 'present')
      provider.update(context, 'example.com', name: 'example.com', comment: 'new', ensure: 'present')
    end

    it 'leaves the unmarked twin alone under :skip_unmarked too' do
      allow(provider).to receive(:adoption_policy).and_return(:skip_unmarked)
      expect(transport).not_to receive(:patch).with(context, '/Test/Thing/1', anything)
      expect(transport).to receive(:patch).with(context, '/Test/Thing/2', anything)
      provider.update(context, 'example.com', name: 'example.com', comment: 'new', ensure: 'present')
    end

    it 'insync? judges the marked object' do
      provider.get(context, ['example.com'])
      expect(provider.insync?(context, 'example.com', :ensure, false, ensure: 'absent')).to be_nil
    end

    it 'purge never lists or deletes the unmarked twin' do
      expect(provider.get(context)).to eq([{ name: 'Example.com', comment: 'ours', ensure: 'present' }])
      provider.plan_deletions(:run, ['Example.com'])
      expect(transport).not_to receive(:delete).with(context, '/Test/Thing/1')
      expect(transport).to receive(:delete).with(context, '/Test/Thing/2')
      provider.set(context, 'Example.com' => { is: { name: 'Example.com', ensure: 'present' }, should: { name: 'Example.com', ensure: 'absent' } })
    end
  end

  describe 'case-insensitive keys' do
    it 'finds an object whose name differs from the key only in case' do
      expect(provider.find_unique([obj(1, 'foo')], 'Foo')['id']).to eq(1)
    end

    it 'folds non-ASCII letters too' do
      expect(provider.find_unique([obj(1, 'CAFÉ wing')], 'café Wing')['id']).to eq(1)
    end

    it 'raises on two objects differing only in case' do
      expect { provider.find_unique([obj(1, 'Foo'), obj(2, 'FOO')], 'foo') }
        .to raise_error(Puppet::ResourceError, %r{glpi_thing.*2 GLPI objects.*ids 1, 2})
    end

    it 'compares case-sensitively when the provider class opts out' do
      sensitive = Class.new(provider_class) { def self.case_sensitive_keys? = true }.new
      expect(sensitive.find_unique([obj(1, 'foo')], 'Foo')).to be_nil
      expect(sensitive.find_unique([obj(1, 'Foo'), obj(2, 'FOO')], 'foo')).to be_nil
      expect(sensitive.find_unique([obj(1, 'Foo'), obj(2, 'FOO')], 'FOO')['id']).to eq(2)
    end

    context 'with Foo declared and foo in GLPI' do
      let(:objects) { [obj(1, 'foo', "#{marker}\nmine")] }

      it 'get reports it present under the declared title' do
        expect(provider.get(context, ['Foo'])).to eq([{ name: 'Foo', comment: 'mine', ensure: 'present' }])
      end

      it 'create updates the object instead of posting a second one' do
        expect(transport).not_to receive(:post)
        expect(transport).to receive(:patch).with(context, '/Test/Thing/1', { 'name' => 'Foo', 'comment' => "#{marker}\nmine" })
        provider.create(context, 'Foo', name: 'Foo', comment: 'mine', ensure: 'present')
      end

      context 'when the provider has nothing to write' do
        let(:provider_class) { Puppet::Provider::GlpiThing::Quiet }

        it 'update and create of a marked object send no empty PATCH' do
          expect(transport).not_to receive(:patch)
          provider.update(context, 'Foo', name: 'Foo', ensure: 'present')
          provider.create(context, 'Foo', name: 'Foo', ensure: 'present')
        end
      end

      it 'update and delete find it' do
        expect(transport).to receive(:patch).with(context, '/Test/Thing/1', anything)
        provider.update(context, 'Foo', name: 'Foo', comment: 'x', ensure: 'present')
        expect(transport).to receive(:delete).with(context, '/Test/Thing/1')
        provider.delete(context, 'Foo')
      end
    end

    it 'fails a requested name when GLPI has Foo and FOO' do
      objects.push(obj(1, 'Foo', marker), obj(2, 'FOO', marker))
      expect { provider.get(context, ['foo']) }.to raise_error(Puppet::ResourceError, %r{ids 1, 2})
    end

    it 'lists two marked objects differing only in case as one skipped key' do
      objects.push(obj(1, 'Foo', marker), obj(2, 'FOO', marker))
      expect(context).to receive(:warning).with(%r{2 GLPI objects share the key.*ids 1, 2})
      expect(provider.get(context)).to eq([])
    end

    it 'never deletes the declared object through a purge title differing only in case' do
      objects.push(obj(1, 'foo', marker))
      provider.plan_deletions(:run, ['foo'], ['Foo'])
      expect(transport).not_to receive(:delete)
      expect(context).to receive(:warning).with(%r{'foo'.*differing only in case})
      provider.set(context, 'foo' => { is: { name: 'foo', ensure: 'present' }, should: { name: 'foo', ensure: 'absent' } })
    end

    it 'does not count a declared case-variant against the purge guard' do
      objects.replace([obj(1, 'foo', marker), obj(2, 'other', marker)])
      provider.plan_deletions(:run, ['foo', 'other'], ['Foo'])
      expect(transport).to receive(:delete).with(context, '/Test/Thing/2')
      provider.set(context, 'other' => { is: { name: 'other', ensure: 'present' }, should: { name: 'other', ensure: 'absent' } })
    end

    it 'still deletes an undeclared object' do
      objects.push(obj(1, 'foo', marker))
      provider.plan_deletions(:run, ['foo'], ['bar'])
      expect(transport).to receive(:delete).with(context, '/Test/Thing/1')
      provider.set(context, 'foo' => { is: { name: 'foo', ensure: 'present' }, should: { name: 'foo', ensure: 'absent' } })
    end
  end

  describe 'trashed objects' do
    let(:objects) { [obj(1, 'gone', marker).merge('is_deleted' => true), obj(2, 'live', marker)] }

    it 'are not listed for purge' do
      expect(provider.get(context).map { |r| r[:name] }).to eq(['live'])
    end

    it 'are not matched when a name is requested' do
      expect(provider.get(context, ['gone'])).to eq([])
    end

    it 'are not adopted: a new object is created and the trash is mentioned' do
      objects[0]['comment'] = 'by hand'
      expect(transport).to(receive(:post).with(context, '/Test/Thing', { 'name' => 'gone', 'comment' => marker }) { |*args| store_post(*args) })
      expect(context).to receive(:warning).with(%r{trashed GLPI object 'gone' \(id 1\).*new object is created})
      provider.create(context, 'gone', name: 'gone', ensure: 'present')
    end

    it 'are found by the warning case-insensitively, whatever form is_deleted takes' do
      objects[0]['is_deleted'] = 1
      expect(context).to receive(:warning).with(%r{trashed GLPI object 'GONE'})
      provider.create(context, 'GONE', name: 'GONE', ensure: 'present')
    end

    it 'do not make a live key ambiguous' do
      objects << obj(3, 'LIVE', marker).merge('is_deleted' => true)
      expect(provider.get(context, ['live']).map { |r| r[:name] }).to eq(['live'])
    end

    it 'are not deleted' do
      expect(transport).not_to receive(:delete)
      provider.delete(context, 'gone')
    end

    it 'say nothing when the object created has no trashed twin' do
      expect(context).not_to receive(:warning)
      provider.create(context, 'fresh', name: 'fresh', ensure: 'present')
    end
  end

  describe 'restore_trashed' do
    let(:config) { super().merge('restore_trashed' => true) }
    let(:objects) { [obj(1, 'gone', "#{marker}\nold").merge('is_deleted' => true)] }

    before(:each) do
      allow(transport).to receive(:patch) do |_ctx, path, body|
        objects.find { |o| "/Test/Thing/#{o['id']}" == path }.merge!(body)
      end
    end

    it 'is off by default, on from the file, per type overridable' do
      File.write(config_file, config.merge('restore_trashed' => nil).to_yaml)
      expect(provider.restore_trashed?).to be false
      File.write(config_file, config.merge('restore_trashed' => false, 'type_restore_trashed' => { 'glpi_thing' => true }).to_yaml)
      expect(Puppet::Provider::GlpiThing::GlpiThing.new.restore_trashed?).to be true
      File.write(config_file, config.merge('type_restore_trashed' => { 'glpi_thing' => false }).to_yaml)
      expect(Puppet::Provider::GlpiThing::GlpiThing.new.restore_trashed?).to be false
    end

    it 'restores a marked trashed object instead of POSTing' do
      expect(transport).not_to receive(:post)
      expect(transport).to receive(:patch) do |_ctx, path, body|
        expect(path).to eq('/Test/Thing/1')
        expect(body).to eq('name' => 'gone', 'comment' => "#{marker}\nnew", 'is_deleted' => false)
        objects.first.merge!(body)
      end
      expect(context).not_to receive(:warning)
      provider.create(context, 'gone', name: 'gone', comment: 'new', ensure: 'present')
      expect(provider.get(context, ['gone']).map { |r| r[:comment] }).to eq(['new'])
      expect(provider.lookup_object(context, 'gone')['id']).to eq(1)
    end

    it 'never restores an unmarked trashed object' do
      objects[0]['comment'] = 'by hand'
      expect(transport).not_to receive(:patch)
      expect(transport).to(receive(:post).with(context, '/Test/Thing', { 'name' => 'gone', 'comment' => marker }) { |*args| store_post(*args) })
      expect(context).to receive(:warning).with(%r{trashed GLPI object 'gone' \(id 1\).*new object is created})
      provider.create(context, 'gone', name: 'gone', ensure: 'present')
    end

    it 'does not restore when the setting is off' do
      File.write(config_file, config.merge('restore_trashed' => false).to_yaml)
      expect(transport).not_to receive(:patch)
      expect(transport).to(receive(:post) { |*args| store_post(*args) })
      provider.create(context, 'gone', name: 'gone', ensure: 'present')
    end

    it 'raises on two marked trashed matches' do
      objects << obj(2, 'GONE', marker).merge('is_deleted' => true)
      expect(transport).not_to receive(:patch)
      expect { provider.create(context, 'gone', name: 'gone', ensure: 'present') }
        .to raise_error(Puppet::ResourceError, %r{2 trashed GLPI objects.*ids 1, 2})
    end

    it 'warns about an unmarked trashed twin when restoring the marked one' do
      objects << obj(2, 'Gone', 'by hand').merge('is_deleted' => true)
      expect(transport).to receive(:patch).with(context, '/Test/Thing/1', anything) { |_c, _p, body| objects.first.merge!(body) }
      expect(context).to receive(:warning).with(%r{unmarked trashed GLPI object 'Gone' \(id 2\).*stays in the trash.*id 1})
      provider.create(context, 'gone', name: 'gone', ensure: 'present')
    end

    it 'prefers a live object over the trash' do
      objects << obj(2, 'gone', marker)
      expect(transport).to receive(:patch).with(context, '/Test/Thing/2', anything)
      provider.create(context, 'gone', name: 'gone', ensure: 'present')
    end
  end

  describe '#get' do
    let(:objects) { [obj(1, 'ours', "#{marker}\nmine"), obj(2, 'theirs', 'by hand'), obj(3, 'other')] }

    it 'without names (purge, puppet resource) returns only marked objects' do
      expect(provider.get(context)).to eq([{ name: 'ours', comment: 'mine', ensure: 'present' }])
      expect(provider.get(context, [])).to eq([{ name: 'ours', comment: 'mine', ensure: 'present' }])
    end

    it 'with names returns requested unmarked objects too (skip_unmarked)' do
      allow(provider).to receive(:adoption_policy).and_return(:skip_unmarked)
      expect(provider.get(context, ['theirs'])).to eq([{ name: 'theirs', comment: 'by hand', ensure: 'present' }])
    end

    it 'reports an unmarked object as absent under :adopt, so create() adopts it' do
      expect(provider.get(context, ['theirs'])).to eq([])
      expect(provider.get(context, ['ours'])).to eq([{ name: 'ours', comment: 'mine', ensure: 'present' }])
    end

    it 'returns every matching object under :match_only' do
      allow(provider).to receive(:adoption_policy).and_return(:match_only)
      expect(provider.get(context, ['theirs']).map { |r| r[:name] }).to eq(['theirs'])
      expect(provider.get(context).map { |r| r[:name] }).to eq(['ours', 'theirs', 'other'])
    end

    it 'returns the requested title as namevar when GLPI returns it entity-encoded' do
      objects << obj(4, 'A &#38; B', marker)
      expect(provider.get(context, ['A & B']).first[:name]).to eq('A & B')
    end

    it 'fails a requested name with two GLPI matches' do
      objects << obj(5, 'ours', marker)
      expect { provider.get(context, ['ours']) }.to raise_error(Puppet::ResourceError, %r{ids 1, 5})
    end

    it 'skips marked duplicates with a warning when listing' do
      objects << obj(5, 'ours', marker)
      expect(context).to receive(:warning).with(%r{ours})
      expect(provider.get(context)).to eq([])
    end

    it 'reads the collection once per run, not per resource' do
      expect(transport).to receive(:get_all).once.and_return(objects)
      provider.get(context, ['ours'])
      provider.get(context, ['theirs'])
    end

    it 'treats a missing transport file as no objects (first run)' do
      File.delete(config_file)
      expect(provider.get(context, ['ours'])).to eq([])
    end
  end

  describe '#create' do
    def accept_posts
      allow(transport).to receive(:post) do |_ctx, _path, body|
        objects << body.merge('id' => 40)
        { 'id' => 40, 'href' => '/Test/Thing/40' }
      end
    end

    it 'posts a new object with the marker first in the comment' do
      expect(transport).to receive(:post).with(context, '/Test/Thing', { 'name' => 'new', 'comment' => "#{marker}\nhello" })
                                         .and_return('id' => 40)
      allow(transport).to receive(:get).with(context, '/Test/Thing/40').and_return(obj(40, 'new', "#{marker}\nhello"))
      provider.create(context, 'new', name: 'new', comment: 'hello', ensure: 'present')
    end

    it 'reads the created object back even when nothing is cached' do
      accept_posts
      expect(transport).to(receive(:get).with(context, '/Test/Thing/40') { objects.find { |o| o['id'] == 40 }.dup })
      provider.create(context, 'new', name: 'new', comment: 'hello', ensure: 'present')
    end

    it 'fails the resource when the POST answer carries no id' do
      allow(transport).to receive(:post).and_return(nil)
      expect { provider.create(context, 'new', name: 'new', comment: 'hello', ensure: 'present') }
        .to raise_error(Puppet::ResourceError, %r{glpi_thing.*'new'.*no id})
    end

    it 'fails the resource when the created object cannot be read back (it would be created again next run)' do
      allow(transport).to receive(:post).and_return('id' => 40)
      allow(transport).to receive(:get).with(context, '/Test/Thing/40')
                                       .and_raise(Puppet::ResourceError, 'GLPI API error 403 on GET /Test/Thing/40')
      expect { provider.create(context, 'new', name: 'new', comment: 'hello', ensure: 'present') }
        .to raise_error(Puppet::ResourceError, %r{glpi_thing.*'new'.*/Test/Thing/40.*cannot be read back.*403})
    end

    it 'fails the resource when the read-back returns another object or nothing' do
      allow(transport).to receive(:post).and_return('id' => 40)
      allow(transport).to receive(:get).with(context, '/Test/Thing/40').and_return(nil)
      expect { provider.create(context, 'new', name: 'new', comment: 'hello', ensure: 'present') }
        .to raise_error(Puppet::ResourceError, %r{cannot be read back})
    end

    it 'adopts an unmarked same-name object instead of creating a duplicate' do
      objects << obj(7, 'theirs', 'by hand')
      expect(transport).not_to receive(:post)
      expect(transport).to receive(:patch).with(context, '/Test/Thing/7', { 'name' => 'theirs', 'comment' => "#{marker}\nhello" })
      provider.create(context, 'theirs', name: 'theirs', comment: 'hello', ensure: 'present')
    end

    it 'appends the marker to the existing comment when the type has no comment attribute' do
      plain = Puppet::Provider::GlpiThing::Plain.new
      allow(Puppet::Provider::GlpiThing::Plain).to receive_messages(config_path: config_file, build_transport: transport)
      objects << obj(7, 'theirs', 'by hand')
      expect(transport).to receive(:patch).with(context, '/Test/Thing/7', { 'name' => 'theirs', 'comment' => "by hand\n#{marker}" })
      plain.create(context, 'theirs', name: 'theirs', ensure: 'present')
    end

    it 'never writes an unmarked object under :skip_unmarked' do
      allow(provider).to receive(:adoption_policy).and_return(:skip_unmarked)
      objects << obj(7, 'theirs', 'by hand')
      expect(transport).not_to receive(:post)
      expect(transport).not_to receive(:patch)
      expect(context).to receive(:warning).with(%r{theirs})
      provider.create(context, 'theirs', name: 'theirs', comment: 'x', ensure: 'present')
    end
  end

  describe '#update' do
    it 'patches the matched object and keeps the marker' do
      objects << obj(3, 'ours', marker)
      expect(transport).to receive(:patch).with(context, '/Test/Thing/3', { 'name' => 'ours', 'comment' => "#{marker}\nnew" })
      provider.update(context, 'ours', name: 'ours', comment: 'new', ensure: 'present')
    end

    it 'does not mark under :match_only' do
      allow(provider).to receive(:adoption_policy).and_return(:match_only)
      objects << obj(3, 'theirs', 'by hand')
      expect(transport).to receive(:patch).with(context, '/Test/Thing/3', { 'name' => 'theirs', 'comment' => 'x' })
      provider.update(context, 'theirs', name: 'theirs', comment: 'x', ensure: 'present')
    end
  end

  describe 'deletion' do
    it 'skips the delete of an unmarked object with a warning' do
      allow(provider).to receive(:adoption_policy).and_return(:skip_unmarked)
      objects << obj(9, 'theirs', 'by hand')
      expect(transport).not_to receive(:delete)
      expect(context).to receive(:warning).with(%r{theirs.*not carry the marker})
      provider.plan_deletions(:run, ['theirs'])
      provider.set(context, 'theirs' => { is: { name: 'theirs', ensure: 'present' }, should: { name: 'theirs', ensure: 'absent' } })
    end

    it 'warns again in the next run, and the warning memory does not grow across runs' do
      allow(provider).to receive(:adoption_policy).and_return(:skip_unmarked)
      objects << obj(9, 'theirs', 'by hand')
      expect(context).to receive(:warning).with(%r{theirs.*not carry the marker}).exactly(3).times
      sizes = [:run1, :run2, :run3].map do |run|
        provider.plan_deletions(run, ['theirs'])
        provider.invalidate_objects
        provider.delete(context, 'theirs')
        provider.delete(context, 'theirs') # same run: no second warning
        provider.instance_variable_get(:@warned).size
      end
      expect(sizes).to eq([1, 1, 1])
    end

    it 'starts every once-per-run warning memory empty in a new run' do
      ivars = [:@twins_noted, :@warned, :@warned_links, :@warned_fields, :@warned_missing, :@warned_entities, :@warned_members]
      ivars.each { |ivar| provider.instance_variable_set(ivar, Set.new([:old])) }
      provider.plan_deletions(:next_run, [])
      expect(ivars.map { |ivar| provider.instance_variable_get(ivar).size }).to all(eq(0))
    end

    it 'never deletes under :match_only' do
      allow(provider).to receive(:adoption_policy).and_return(:match_only)
      objects << obj(9, 'ours', marker)
      expect(transport).not_to receive(:delete)
      expect(context).to receive(:warning).with(%r{ours})
      provider.delete(context, 'ours')
    end

    it 'deletes a marked object' do
      objects << obj(9, 'ours', marker)
      expect(transport).to receive(:delete).with(context, '/Test/Thing/9')
      provider.delete(context, 'ours')
    end
  end

  describe 'purge guard' do
    let(:objects) { (1..4).map { |i| obj(i, "r#{i}", marker) } + [obj(10, 'theirs', 'by hand')] }

    def deletion(name)
      { is: { name: name, ensure: 'present' }, should: { name: name, ensure: 'absent' } }
    end

    def creation(name)
      { is: { name: name, ensure: 'absent' }, should: { name: name, ensure: 'present' } }
    end

    context 'with an empty plan for the run' do
      before(:each) { provider.plan_deletions(:run, []) }

      it 'set raises and deletes nothing when 3 of 4 managed objects would be deleted at purge_max_fraction 0.5' do
        expect(transport).not_to receive(:delete)
        expect { provider.set(context, 'r1' => deletion('r1'), 'r2' => deletion('r2'), 'r3' => deletion('r3')) }
          .to raise_error(Puppet::ResourceError, %r{glpi_thing.*3 of 4.*allows 2})
      end

      it 'allows floor(fraction x managed) deletions' do
        expect(transport).to receive(:delete).twice
        provider.set(context, 'r1' => deletion('r1'), 'r2' => deletion('r2'))
      end

      it 'always allows one deletion' do
        objects.replace([obj(1, 'r1', marker)])
        expect(transport).to receive(:delete).once
        provider.set(context, 'r1' => deletion('r1'))
      end

      it 'does not count unmarked objects' do
        expect(transport).to receive(:delete).twice
        provider.set(context, 'r1' => deletion('r1'), 'r2' => deletion('r2'), 'theirs' => deletion('theirs'))
      end
    end

    context 'with an absolute cap per run' do
      let(:objects) { (1..20).map { |i| obj(i, "r#{i}", marker) } }

      def deletions(count)
        (1..count).to_h { |i| ["r#{i}", deletion("r#{i}")] }
      end

      before(:each) { provider.plan_deletions(:run, []) }

      it 'caps at 3 deletions per scope and run by default, below the fraction' do
        expect(transport).not_to receive(:delete)
        expect { provider.set(context, deletions(4)) }
          .to raise_error(Puppet::ResourceError, %r{glpi_thing.*4 of 20.*purge_max_per_run 3.*allows 3})
      end

      it 'lets the capped number through' do
        expect(transport).to receive(:delete).exactly(3).times
        provider.set(context, deletions(3))
      end

      context 'with purge_max_per_run set' do
        let(:config) { super().merge('purge_max_per_run' => 5) }

        it 'uses it' do
          expect(transport).to receive(:delete).exactly(5).times
          provider.set(context, deletions(5))
          expect { provider.set(context, 'r6' => deletion('r6')) }.to raise_error(Puppet::ResourceError, %r{6 of 20.*allows 5})
        end
      end

      [0, nil].each do |off|
        context "with purge_max_per_run #{off.inspect}" do
          let(:config) { super().merge('purge_max_per_run' => off) }

          it 'leaves only the fraction' do
            expect(transport).to receive(:delete).exactly(10).times
            provider.set(context, deletions(10))
          end
        end
      end

      context 'when the fraction allows fewer than the cap' do
        let(:config) { super().merge('purge_max_fraction' => 0.1, 'purge_max_per_run' => 5) }

        it 'keeps the smaller allowance' do
          expect { provider.set(context, deletions(3)) }.to raise_error(Puppet::ResourceError, %r{3 of 20.*allows 2})
        end
      end
    end

    it 'refuses any deletion when the run has no plan (type did not register the hook)' do
      expect(transport).not_to receive(:delete)
      expect { provider.set(context, 'r1' => deletion('r1')) }
        .to raise_error(Puppet::ResourceError, %r{glpi_thing.*no deletion plan.*register})
    end

    it 'measures against the managed count from before the run wrote anything' do
      allow(transport).to receive(:post) { |*args| store_post(*args) }
      provider.plan_deletions(:rename, ['r1', 'r2', 'r3', 'r4'])
      provider.set(context, (1..4).to_h { |i| ["n#{i}", creation("n#{i}")] })
      expect(objects.count { |o| o['comment'].include?(marker) }).to eq(8)
      expect(transport).not_to receive(:delete)
      expect { provider.set(context, 'r1' => deletion('r1')) }.to raise_error(Puppet::ResourceError, %r{4 of 4.*allows 2})
    end

    it 'counts the deletions the catalog plans, so per-resource set calls delete nothing either' do
      provider.plan_deletions(:catalog1, ['r1', 'r2', 'r3'])
      expect(transport).not_to receive(:delete)
      expect { provider.set(context, 'r1' => deletion('r1')) }.to raise_error(Puppet::ResourceError, %r{3 of 4})
    end

    it 'lets every planned deletion through when the plan is within the guard' do
      provider.plan_deletions(:catalog1, ['r1', 'r2'])
      expect(transport).to(receive(:delete).twice { |_ctx, path| objects.reject! { |o| path.end_with?("/#{o['id']}") } })
      provider.set(context, 'r1' => deletion('r1'))
      provider.set(context, 'r2' => deletion('r2'))
    end

    it 'counts deletions already done this run' do
      provider.plan_deletions(:run, [])
      expect(transport).to receive(:delete).twice
      provider.set(context, 'r1' => deletion('r1'))
      provider.set(context, 'r2' => deletion('r2'))
      expect { provider.set(context, 'r3' => deletion('r3')) }.to raise_error(Puppet::ResourceError, %r{allows 2})
    end

    context 'with a guard scope' do
      let(:provider_class) { Puppet::Provider::GlpiThing::Scoped }
      let(:config) { super().merge('purge_max_fraction' => 0.2) }
      let(:objects) { (1..5).map { |i| obj(i, "a-#{i}", marker) } + [obj(20, 'b-1', marker)] }

      it 'defaults to the empty scope' do
        expect(Puppet::Provider::GlpiThing::GlpiThing.new.guard_scope('x')).to eq('')
        expect(Puppet::Provider::GlpiThing::GlpiThing.new.guard_scope(obj(1, 'x'))).to eq('')
      end

      it 'counts per scope' do
        provider.plan_deletions(:scoped, ['a-1', 'b-1'])
        expect(transport).to receive(:delete).with(context, '/Test/Thing/20')
        provider.set(context, 'b-1' => deletion('b-1'))
        expect(transport).to receive(:delete).with(context, '/Test/Thing/1')
        provider.set(context, 'a-1' => deletion('a-1'))
      end

      it 'refuses a scope over its allowance and nothing else' do
        provider.plan_deletions(:scoped2, ['a-1', 'a-2', 'a-3', 'b-1'])
        expect(transport).not_to receive(:delete).with(context, %r{/Test/Thing/[1-3]\z})
        expect { provider.set(context, 'a-1' => deletion('a-1')) }
          .to raise_error(Puppet::ResourceError, %r{3 of 5.*allows 1})
        expect(transport).to receive(:delete).with(context, '/Test/Thing/20')
        provider.set(context, 'b-1' => deletion('b-1'))
      end

      it 'counts the deletions done per scope' do
        provider.plan_deletions(:scoped3, [])
        expect(transport).to receive(:delete).with(context, '/Test/Thing/20')
        provider.set(context, 'b-1' => deletion('b-1'))
        expect(transport).to receive(:delete).with(context, '/Test/Thing/1')
        provider.set(context, 'a-1' => deletion('a-1'))
        expect { provider.set(context, 'a-2' => deletion('a-2')) }.to raise_error(Puppet::ResourceError, %r{2 of 5})
      end
    end

    context 'with composite titles whose own scope differs from the object' do
      let(:provider_class) { Puppet::Provider::GlpiThing::Composite }
      let(:config) { super().merge('purge_max_fraction' => 0.2) }
      let(:objects) do
        (1..5).map { |i| obj(i, "r#{i}", marker).merge('kind' => 'a') } + [obj(20, 'r1', marker).merge('kind' => 'b')]
      end

      def title(kind, name)
        { kind: kind, name: name }
      end

      def composite_deletion(kind, name)
        { is: title(kind, name).merge(ensure: 'present'), should: title(kind, name).merge(ensure: 'absent') }
      end

      it 'counts pending deletions in the scope of the live object they name' do
        provider.plan_deletions(:composite, [title('a', 'r1'), title('a', 'r2'), title('a', 'r3')])
        expect(transport).not_to receive(:delete)
        expect { provider.set(context, title('a', 'r1') => composite_deletion('a', 'r1')) }
          .to raise_error(Puppet::ResourceError, %r{glpi_thing \(a\).*3 of 5.*allows 1})
      end

      it 'matches by the whole natural key: the same name in another scope is another object' do
        provider.plan_deletions(:composite2, [title('b', 'r1')])
        expect(transport).to receive(:delete).with(context, '/Test/Thing/20')
        provider.set(context, title('b', 'r1') => composite_deletion('b', 'r1'))
        expect(transport).to receive(:delete).with(context, '/Test/Thing/1')
        provider.set(context, title('a', 'r1') => composite_deletion('a', 'r1'))
        expect { provider.set(context, title('a', 'r2') => composite_deletion('a', 'r2')) }
          .to raise_error(Puppet::ResourceError, %r{2 of 5})
      end
    end
  end

  # Spies: the transport stub keeps GLPI's state, requests are counted after.
  # rubocop:disable RSpec/MessageSpies
  describe 'write-through cache' do
    let(:objects) { (1..5).map { |i| obj(i, "r#{i}", marker) } }

    def present(name, comment)
      { name: name, comment: comment, ensure: 'present' }
    end

    # A transport that keeps GLPI's state across calls: POST adds, PATCH
    # merges, DELETE removes.
    before(:each) do
      allow(transport).to receive(:post) do |_ctx, _path, body|
        id = objects.map { |o| o['id'] }.max + 1
        objects << body.merge('id' => id)
        { 'id' => id, 'href' => "/Test/Thing/#{id}" }
      end
      allow(transport).to receive(:patch) do |_ctx, path, body|
        objects.find { |o| "/Test/Thing/#{o['id']}" == path }.merge!(body)
      end
      allow(transport).to receive(:delete) { |_ctx, path| objects.reject! { |o| "/Test/Thing/#{o['id']}" == path } }
    end

    it 'updating N objects costs one list read, N writes and N item reads' do
      names = objects.map { |o| o['name'] }
      provider.plan_deletions(:run, [])
      names.each do |name|
        is = provider.get(context, [name]).first
        provider.set(context, name => { is: is, should: present(name, 'new') })
      end
      expect(transport).to have_received(:get_all).once
      expect(transport).to have_received(:patch).exactly(5).times
      expect(transport).to have_received(:get).exactly(5).times
      expect(provider.get(context, names).map { |r| r[:comment] }).to eq(['new'] * 5)
      expect(transport).to have_received(:get_all).once
    end

    it 'replaces the written object by id, so the next get sees the write without a list read' do
      provider.update(context, 'r1', present('r1', 'changed'))
      expect(provider.get(context, ['r1'])).to eq([present('r1', 'changed')])
      expect(transport).to have_received(:get_all).once
      expect(transport).to have_received(:get).with(context, '/Test/Thing/1')
    end

    it 'never POSTs a duplicate of an object created earlier in the same run' do
      provider.get(context, ['n1'])
      provider.plan_deletions(:run, [])
      provider.set(context, 'n1' => { is: nil, should: present('n1', 'first') })
      provider.set(context, 'n2' => { is: nil, should: present('n2', 'other') })
      # A second resource of the same object (e.g. a stale "absent" state).
      provider.set(context, 'n1' => { is: nil, should: present('n1', 'second') })
      expect(transport).to have_received(:post).twice
      expect(objects.count { |o| o['name'] == 'n1' }).to eq(1)
      expect(objects.find { |o| o['name'] == 'n1' }['comment']).to eq("#{marker}
second")
    end

    it 'reads the list again before the first create of a run, and not before later ones' do
      provider.get(context, ['n1'])
      provider.plan_deletions(:run, [])
      provider.set(context, 'n1' => { is: nil, should: present('n1', 'x') })
      provider.set(context, 'n2' => { is: nil, should: present('n2', 'x') })
      provider.set(context, 'n3' => { is: nil, should: present('n3', 'x') })
      expect(transport).to have_received(:get_all).twice
    end

    it 'sees an object another writer created before the run, read fresh at the first create' do
      provider.get(context, ['n1'])
      objects << obj(50, 'n1', 'made elsewhere')
      provider.plan_deletions(:run, [])
      provider.set(context, 'n1' => { is: nil, should: present('n1', 'x') })
      expect(transport).not_to have_received(:post)
      expect(transport).to have_received(:patch).with(context, '/Test/Thing/50', anything)
    end

    it 'without a deletion plan (no run marker) every create reads the list again' do
      provider.create(context, 'n1', present('n1', 'x'))
      provider.create(context, 'n2', present('n2', 'x'))
      expect(transport).to have_received(:get_all).twice
    end

    it 'fails the resource and reads the list again when the POST response carries no id' do
      allow(transport).to receive(:post) { |_ctx, _path, body| objects << body.merge('id' => 77) && nil }
      provider.plan_deletions(:run, [])
      provider.get(context, ['n1'])
      expect { provider.create(context, 'n1', present('n1', 'x')) }.to raise_error(Puppet::ResourceError, %r{no id})
      expect(provider.get(context, ['n1'])).to eq([present('n1', 'x')])
      expect(transport).not_to have_received(:get)
      expect(transport).to have_received(:get_all).twice
    end

    it 'falls back to a full read when the item re-read fails' do
      allow(transport).to receive(:get).and_raise(Puppet::ResourceError, 'GLPI API error 500')
      provider.update(context, 'r1', present('r1', 'changed'))
      expect(provider.get(context, ['r1'])).to eq([present('r1', 'changed')])
      expect(transport).to have_received(:get_all).twice
    end

    it 'falls back to a full read when the re-read object lacks a field the cached one had' do
      allow(transport).to receive(:get) { |_ctx, _p, _q = nil| { 'id' => 1, 'name' => 'r1' } }
      provider.update(context, 'r1', present('r1', 'changed'))
      provider.get(context, ['r1'])
      expect(transport).to have_received(:get_all).twice
    end

    it 'drops the cache when the write itself fails' do
      allow(transport).to receive(:patch).and_raise(Puppet::ResourceError, 'GLPI API error 500')
      expect { provider.update(context, 'r1', present('r1', 'changed')) }.to raise_error(Puppet::ResourceError)
      provider.get(context, ['r1'])
      expect(transport).to have_received(:get_all).twice
      expect(transport).not_to have_received(:get)
    end

    it 'removes a deleted object from the cache without reading again' do
      provider.plan_deletions(:run, ['r1'])
      provider.set(context, 'r1' => { is: provider.get(context, ['r1']).first, should: { name: 'r1', ensure: 'absent' } })
      expect(provider.get(context, ['r1'])).to eq([])
      expect(provider.get(context).map { |r| r[:name] }).to eq(['r2', 'r3', 'r4', 'r5'])
      expect(transport).to have_received(:get_all).once
      expect(transport).not_to have_received(:get)
    end

    it 'does not extend the cache lifetime: an expired list is read whole again' do
      start = Time.now
      allow(Time).to receive(:now).and_return(start)
      provider.get(context, ['r1'])
      allow(Time).to receive(:now).and_return(start + 30)
      provider.update(context, 'r1', present('r1', 'changed'))
      allow(Time).to receive(:now).and_return(start + 61)
      provider.get(context, ['r1'])
      expect(transport).to have_received(:get_all).twice
    end

    it 'keeps the purge baseline at the managed count from before the run wrote anything' do
      provider.plan_deletions(:rename, ['r1', 'r2', 'r3'])
      provider.set(context, (1..4).to_h { |i| ["n#{i}", { is: nil, should: present("n#{i}", 'x') }] })
      expect(provider.get(context).size).to eq(9)
      expect(transport).not_to receive(:delete)
      expect { provider.set(context, 'r1' => { is: present('r1', ''), should: { name: 'r1', ensure: 'absent' } }) }
        .to raise_error(Puppet::ResourceError, %r{3 of 5.*allows 2})
    end
  end

  describe 'shared lookup lists' do
    it 'drops the shared list of the collection when a POST answers without an id' do
      other.shared_list(context, '/Test/Thing')
      allow(transport).to receive(:post).and_return(nil)
      expect { provider.create(context, 'n1', name: 'n1', comment: 'x', ensure: 'present') }.to raise_error(Puppet::ResourceError)
      other.shared_list(context, '/Test/Thing')
      expect(transport).to have_received(:get_all).with(context, '/Test/Thing', anything).exactly(3).times
    end

    it 'drops the shared list of the collection when a write fails' do
      objects << obj(3, 'ours', marker)
      other.shared_list(context, '/Test/Thing')
      allow(transport).to receive(:patch).and_raise(Puppet::ResourceError, 'GLPI API error 500')
      expect { provider.update(context, 'ours', name: 'ours', comment: 'new', ensure: 'present') }.to raise_error(Puppet::ResourceError)
      other.shared_list(context, '/Test/Thing')
      expect(transport).to have_received(:get_all).with(context, '/Test/Thing', anything).exactly(3).times
    end

    let(:other) { Puppet::Provider::GlpiThing::Plain.new }
    let(:widgets) { [{ 'id' => 1, 'name' => 'Widget A' }] }

    before(:each) do
      allow(Puppet::Provider::GlpiThing::Plain).to receive_messages(config_path: config_file, build_transport: transport)
      allow(transport).to receive(:get_all).with(context, '/Dropdowns/Widget', anything) { widgets.map(&:dup) }
    end

    it 'reads a list once per run for every provider on the same transport' do
      provider.shared_list(context, '/Dropdowns/Widget')
      expect(other.shared_list(context, '/Dropdowns/Widget')).to eq(widgets)
      expect(transport).to have_received(:get_all).with(context, '/Dropdowns/Widget', anything).once
    end

    it 'puts an object the type writes into a cached shared list of its collection' do
      objects << obj(3, 'ours', marker)
      other.shared_list(context, '/Test/Thing')
      allow(transport).to receive(:patch) { |_ctx, _p, body| objects.first.merge!(body) }
      provider.update(context, 'ours', name: 'ours', comment: 'new', ensure: 'present')
      expect(other.shared_list(context, '/Test/Thing').map { |o| o['comment'] }).to eq(["#{marker}
new"])
      expect(transport).to have_received(:get_all).with(context, '/Test/Thing', anything).twice
    end
  end

  # rubocop:enable RSpec/MessageSpies

  describe '#insync?' do
    let(:objects) { [obj(1, 'ours', marker), obj(2, 'theirs', 'by hand')] }
    let(:present) { { name: 'theirs', ensure: 'present', comment: 'by hand' } }

    it 'reports an unmarked object in sync under :skip_unmarked, with a warning' do
      allow(provider).to receive(:adoption_policy).and_return(:skip_unmarked)
      provider.get(context, ['theirs'])
      expect(context).to receive(:warning).with(%r{theirs})
      expect(provider.insync?(context, 'theirs', :comment, present, present.merge(comment: 'x'))).to be true
    end

    it 'reports ensure absent on an unmarked object in sync, with a warning' do
      allow(provider).to receive(:adoption_policy).and_return(:match_only)
      provider.get(context, ['theirs'])
      expect(context).to receive(:warning).with(%r{theirs})
      expect(provider.insync?(context, 'theirs', :ensure, present, name: 'theirs', ensure: 'absent')).to be true
    end

    it 'leaves marked objects to the default comparison' do
      provider.get(context, ['ours'])
      expect(provider.insync?(context, 'ours', :comment, { comment: 'a' }, comment: 'b')).to be_nil
    end
  end

  describe 'transport configuration' do
    it 'splits connection info from module settings' do
      expect(provider_class.connection_info(provider_class.read_transport_config)).to eq(
        base_url: 'https://glpi.example.com/api.php', client_id: 'puppet', client_secret: 'not-a-real-secret',
        username: 'svc', password: 'not-a-real-password', grant_type: 'password', ssl_verify: true
      )
    end

    it 'raises a clear error when the file is missing' do
      File.delete(config_file)
      expect { provider_class.read_transport_config }
        .to raise_error(described_class::TransportConfigMissing, %r{not found at .*glpi_transport\.yaml.*class glpi})
    end

    it 'never puts secrets in the missing-file error' do
      File.write(config_file, "- a list\n")
      expect { provider_class.read_transport_config }.to raise_error(described_class::TransportConfigMissing) { |e|
        expect(e.message).not_to include('not-a-real')
      }
    end

    it 'caches the transport per provider instance' do
      expect(provider_class).to receive(:build_transport).once.and_return(transport)
      provider.transport(context)
      provider.transport(context)
    end

    it 'shares one transport between provider classes with the same config' do
      expect(provider_class).to receive(:build_transport).once.and_return(transport)
      other = Puppet::Provider::GlpiThing::Plain
      allow(other).to receive(:config_path).and_return(config_file)
      allow(other).to receive(:build_transport).and_raise('must not build a second transport')
      first = provider.transport(context)
      expect(other.new.transport(context)).to equal(first)
    end

    it 'builds a new transport when the transport file changes, closing the old one' do
      second = instance_double('Puppet::Transport::Glpi')
      allow(provider_class).to receive(:build_transport).and_return(transport, second)
      expect(transport).to receive(:close)
      expect(provider.transport(context)).to equal(transport)
      File.write(config_file, config.merge('timeout' => 5).to_yaml)
      expect(provider.transport(context)).to equal(second)
    end

    it 'builds a new transport when the file content changes with the same size and mtime' do
      second = instance_double('Puppet::Transport::Glpi')
      allow(provider_class).to receive(:build_transport).and_return(transport, second)
      allow(transport).to receive(:close)
      stamp = File.mtime(config_file)
      expect(provider.transport(context)).to equal(transport)
      File.write(config_file, config.merge('password' => 'not-a-real-passwore').to_yaml)
      File.utime(stamp, stamp, config_file)
      expect(provider.transport(context)).to equal(second)
    end

    it 'refreshes state in set after a first run without the file' do
      File.delete(config_file)
      expect(provider.get(context, ['ours'])).to eq([])
      File.write(config_file, config.to_yaml)
      objects << obj(3, 'ours', marker)
      expect(transport).not_to receive(:post)
      expect(transport).to receive(:patch).with(context, '/Test/Thing/3', { 'name' => 'ours', 'comment' => "#{marker}\nnew" })
      provider.set(context, 'ours' => { is: { name: 'ours', ensure: 'absent' }, should: { name: 'ours', comment: 'new', ensure: 'present' } })
    end
  end

  describe 'type name' do
    it 'derives the type name from the provider class' do
      expect(provider_class.glpi_type_name).to eq('glpi_thing')
    end
  end

  describe 'failure paths' do
    it 'finds the transport file in the confdir' do
      allow(provider_class).to receive(:config_path).and_call_original
      expect(provider_class.config_path).to eq(File.join(Puppet.settings[:confdir], 'glpi_transport.yaml'))
    end

    it 'makes a subclass implement the mapping' do
      bare = described_class.new
      expect { bare.collection_path }.to raise_error(NotImplementedError, %r{collection_path})
      expect { bare.api_to_resource(context, {}) }.to raise_error(NotImplementedError, %r{api_to_resource})
      expect { bare.resource_to_api(context, {}, nil) }.to raise_error(NotImplementedError, %r{resource_to_api})
    end

    it 'keeps a value it cannot coerce, so the type check reports it' do
      expect(provider.to_bool('maybe')).to eq('maybe')
      expect(provider.to_int('12a')).to eq('12a')
    end

    it 'never POSTs for a type that does not create objects' do
      allow(provider).to receive(:creatable?).and_return(false)
      expect(transport).not_to receive(:post)
      expect { provider.create(context, 'new', name: 'new', ensure: 'present') }.to raise_error(Puppet::ResourceError, %r{does not create objects})
    end

    context 'when a delete fails' do
      let(:objects) { [obj(9, 'ours', marker), obj(10, 'other', marker)] }

      before(:each) { allow(transport).to receive(:delete).and_raise(Puppet::ResourceError, 'GLPI said no') }

      it 'raises, does not count it as done, and reads the list again' do
        expect(transport).to receive(:get_all).with(context, '/Test/Thing', anything).twice.and_return(objects)
        provider.plan_deletions(:run, ['ours'])
        provider.get(context, ['ours'])
        expect { provider.delete(context, 'ours') }.to raise_error(Puppet::ResourceError, 'GLPI said no')
        expect(provider.send(:deletions_done)).to eq({})
        provider.get(context, ['ours'])
      end

      it 'reports the failure even when dropping the lists fails too' do
        allow(provider).to receive(:drop_shared_list).and_raise(IOError, 'gone')
        expect { provider.delete(context, 'ours') }.to raise_error(Puppet::ResourceError, 'GLPI said no')
      end
    end

    context 'with an ambiguous key' do
      let(:objects) { [obj(1, 'twin', 'by hand'), obj(2, 'twin', 'by hand')] }

      # insync? must not raise for a state set cannot act on anyway: the
      # default compare runs and find_unique fails the write with the ids.
      it 'leaves it to the default compare, and refuses to write it' do
        provider.plan_deletions(:run, [])
        expect { provider.get(context, ['twin']) }.to raise_error(Puppet::ResourceError, %r{ids 1, 2})
        provider.objects(context)
        expect(provider.insync?(context, 'twin', :comment, { comment: 'a' }, ensure: 'present', comment: 'b')).to be_nil
        expect { provider.update(context, 'twin', name: 'twin', ensure: 'present') }.to raise_error(Puppet::ResourceError, %r{ids 1, 2})
      end
    end

    it 'drops a shared list when the entry cannot be read again' do
      expect(transport).to receive(:get_all).with(context, '/Dropdowns/Thing', anything).twice.and_return([{ 'id' => 1 }])
      provider.shared_list(context, '/Dropdowns/Thing')
      allow(transport).to receive(:get).and_raise(Puppet::ResourceError, 'gone')
      provider.refresh_shared_entry(context, '/Dropdowns/Thing', 1)
      provider.shared_list(context, '/Dropdowns/Thing')
    end

    describe 'first run, with the object still missing after the re-read' do
      let(:provider_class) { Puppet::Provider::GlpiThing::Composite }

      before(:each) do
        allow(type).to receive(:namevars).and_return([:kind, :name])
        File.delete(config_file)
        provider.get(context, [{ kind: 'a', name: 'new' }])
        File.write(config_file, config.to_yaml)
      end

      it 'creates it, from an absent state built from a composite title' do
        title = { kind: 'a', name: 'new' }
        expect(transport).to(receive(:post).once { |*args| store_post(*args) })
        provider.set(context, title => { is: nil, should: title.merge(ensure: 'present', comment: 'x') })
      end

      it 'builds the absent state of a plain title on the type namevar' do
        allow(type).to receive(:namevars).and_return([:name])
        expect(provider.send(:absent_state, context, 'plain')).to eq(name: 'plain', ensure: 'absent')
      end
    end
  end
end
