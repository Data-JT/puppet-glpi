# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_transport_autorequire'

RSpec.describe Puppet::Type::GlpiTransportAutorequire do
  # `instances` asks for every object: Resource API 1.x passes [], 2.x nil.
  def listing
    satisfy('no names') { |names| names.nil? || names.empty? }
  end

  let(:type_name) { :glpi_autorequire_test }
  let(:type_class) { Puppet::Type.type(type_name) }
  let(:fake_provider) { double('provider') } # rubocop:disable RSpec/VerifiedDoubles -- stands in for any glpi_* provider

  before(:each) do
    Puppet::ResourceApi.register_type(
      name: type_name.to_s,
      docs: 'Test type.',
      features: ['simple_get_filter'],
      attributes: {
        ensure: { type: 'Enum[present, absent]', desc: 'Presence.', default: 'present' },
        name:   { type: 'String', desc: 'Name.', behaviour: :namevar },
      },
    )
    described_class.register(type_name)
    allow(type_class).to receive(:my_provider).and_return(fake_provider)
  end

  after(:each) { Puppet::Type.rmtype(type_name) }

  it 'registers an automatic file dependency on the managed transport config path' do
    block = nil
    type_class.eachautorequire { |dependency_type, registered| block = registered if dependency_type == :file }

    expect(block).not_to be_nil
    expect(block.call).to eq(File.join(Puppet.settings[:confdir], 'glpi_transport.yaml'))
  end

  describe 'deletion plan' do
    let(:catalog) { Puppet::Resource::Catalog.new }
    let(:resources) do
      { 'a' => 'absent', 'b' => 'present', 'c' => 'absent' }.map do |name, ensure_value|
        type_class.new(name: name, ensure: ensure_value).tap { |r| catalog.add_resource(r) }
      end
    end

    it 'lists the titles of this type the catalog wants absent' do
      resources
      catalog.add_resource(Puppet::Type.type(:notify).new(name: 'x'))
      expect(described_class.planned_deletions(catalog, type_name)).to eq(['a', 'c'])
    end

    it 'lists the titles of this type the catalog wants present' do
      resources
      catalog.add_resource(Puppet::Type.type(:notify).new(name: 'x'))
      expect(described_class.declared_titles(catalog, type_name)).to eq(['b'])
    end

    it 'includes the resources `resources { purge => true }` generates' do
      resources
      allow(fake_provider).to receive(:get).with(anything, listing).and_return(
        [{ name: 'a', ensure: 'present' }, { name: 'stale', ensure: 'present' }],
      )
      purge = Puppet::Type.type(:resources).new(name: type_name.to_s, purge: true)
      catalog.add_resource(purge)
      generated = purge.generate
      expect(generated.map(&:title)).to eq(['stale'])
      generated.each { |resource| catalog.add_resource(resource) }
      expect(described_class.planned_deletions(catalog, type_name)).to eq(['a', 'c', 'stale'])
    end

    it 'fails closed when a resource of the type lacks the Resource API methods' do
      Puppet::Type.newtype(:glpi_plain_test) { newparam(:name, namevar: true) }
      catalog.add_resource(Puppet::Type.type(:glpi_plain_test).new(name: 'x'))
      expect { described_class.planned_deletions(catalog, :glpi_plain_test) }
        .to raise_error(Puppet::ResourceError, %r{glpi_plain_test.*rsapi_canonicalized_target_state})
    ensure
      Puppet::Type.rmtype(:glpi_plain_test)
    end

    context 'with a purge title that differs from a declared one only in case' do
      def declare(title, catalog, ensure_value = 'present')
        resource = Puppet::Resource.new(type_name, title, parameters: { ensure: ensure_value })
        resource.catalog = catalog
        type_class.new(resource).tap { |ral| catalog.add_resource(ral) }
      end

      before(:each) do
        allow(fake_provider).to receive(:get).with(anything, listing).and_return(
          [{ name: 'STALE', ensure: 'present' }, { name: 'Kept', ensure: 'present' }, { name: 'orphan', ensure: 'present' }],
        )
      end

      it 'does not generate a removal for the variant, only for a truly undeclared instance' do
        declare('stale', catalog)
        declare('Kept', catalog)
        purge = Puppet::Type.type(:resources).new(name: type_name.to_s, purge: true)
        catalog.add_resource(purge)
        expect(purge.generate.map(&:title)).to eq(['orphan'])
      end

      it 'keeps every instance when no declared title matches' do
        declare('unrelated', catalog)
        expect(type_class.instances.map(&:title)).to contain_exactly('STALE', 'Kept', 'orphan')
      end

      it 'forgets the titles of an older catalog that declared the type' do
        declare('stale', Puppet::Resource::Catalog.new)
        declare('other', catalog)
        expect(type_class.instances.map(&:title)).to contain_exactly('STALE', 'Kept', 'orphan')
      end

      it 'forgets them too when the newer catalog declares only another glpi type' do
        other_type = :glpi_autorequire_other
        Puppet::ResourceApi.register_type(
          name: other_type.to_s, docs: 'Other test type.', features: ['simple_get_filter'],
          attributes: {
            ensure: { type: 'Enum[present, absent]', desc: 'Presence.', default: 'present' },
            name:   { type: 'String', desc: 'Name.', behaviour: :namevar }
          }
        )
        described_class.register(other_type)
        declare('stale', Puppet::Resource::Catalog.new)
        newer = Puppet::Resource::Catalog.new
        resource = Puppet::Resource.new(other_type, 'x', parameters: { ensure: 'present' })
        resource.catalog = newer
        Puppet::Type.type(other_type).new(resource)
        expect(type_class.instances.map(&:title)).to contain_exactly('STALE', 'Kept', 'orphan')
      ensure
        Puppet::Type.rmtype(other_type)
      end
    end

    it 'hands the plan to the provider before the first flush of the type' do
      resources
      allow(fake_provider).to receive(:get).and_return([{ name: 'a', ensure: 'present' }])
      allow(fake_provider).to receive(:set)
      expect(fake_provider).to receive(:plan_deletions).with(catalog.object_id, ['a', 'c'], ['b'])
      resources.first.flush
    end
  end
end
