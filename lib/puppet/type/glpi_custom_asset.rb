# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_custom_asset',
  docs: <<-EOS,
@summary Manages a GLPI custom asset (an asset of a custom asset definition) and its custom fields through API v2.

A custom asset is identified by `definition` AND `name`: the asset
definition's system name (e.g. `Website`, the `<definition>` in
`/Assets/Custom/<definition>`) and the asset name. The same name in two
definitions is two resources. Names compare case-insensitively after
HTML-entity decoding and Unicode normalisation.

* The title is `<definition>/<name>`; `definition` and `name` are taken
  from it (the name may contain `/`). A title without `/` fails, and so do
  `definition`/`name` attributes that disagree with the title.
* An unmarked asset of the same definition and name is adopted: it gets the
  marker and is managed from then on (a one-time change).
* The marker is written first in the GLPI comment, followed by `comment`;
  `comment` reads back without it. Unset: the stored comment is kept.
* `asset_type` names a value of the definition's type dropdown
  (`/Assets/Custom/<definition>Type`); a missing one is created. Empty means
  none.
* `delete_properties` clears `asset_type` or `comment` of an existing asset;
  the marker stays. A custom field is cleared by its empty string.
* `entity` is an entity's complete name (`Root entity > Customer A`) or a
  unique entity name; `entity_tag` selects the entity by its tag instead
  (mutually exclusive). Unset: not managed; a new asset is then created in
  the default entity of the API user.
* `fields` are custom fields by their system name. Only the declared keys
  are read, compared and written; other custom fields of the asset are
  never touched. An empty string clears a field. Values compare as text, so
  a dropdown field is declared by the id GLPI stores (as a string) unless it
  is listed in `field_refs`.
* `field_refs` lists the fields of `fields` whose value is the name of a GLPI
  object of the given itemtype: the name is resolved to the id on write and
  the id reads back as the name. A `Computer` matches by name
  case-insensitively, else by the first DNS label. An empty value means none.
  A name that matches nothing leaves the stored value alone with a warning
  (class glpi `unresolved => 'warn'`) or fails the resource after the rest is
  written (`unresolved => 'fail'`); 0 is never written for it.
* `ensure => absent` and purge move a marked asset to the trash; an unmarked
  one is never deleted. With `restore_trashed` (class glpi) a marked trashed
  asset of the same definition and name is restored instead of creating a new
  one. The purge guard counts per definition.

@example A website with custom fields
  glpi_custom_asset { 'Website/www.example.com':
    asset_type => 'Shop',
    entity     => 'Root entity > Customer A',
    comment    => 'Main site',
    fields     => {
      'url'     => 'https://www.example.com/',
      'runs_on' => 'web1.example.com',
    },
    field_refs => { 'runs_on' => 'Computer' },
  }
  EOS
  title_patterns: [
    { pattern: %r{\A(?<definition>[^/]+)/(?<name>.+)\z}m, desc: 'The title "Definition/Name" names the asset definition and the asset.' },
  ],
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    ensure: {
      type: 'Enum[present, absent]',
      desc: 'Whether the asset should be present or absent (absent moves it to the trash).',
      default: 'present',
    },
    definition: {
      type: 'String[1]',
      desc: 'System name of the custom asset definition (e.g. `Website`). Part of the identity.',
      behaviour: :namevar,
    },
    name: {
      type: 'String[1]',
      desc: 'The asset name (unique within its definition).',
      behaviour: :namevar,
    },
    asset_type: {
      type: 'Optional[String]',
      desc: 'Name of the value of the definition type dropdown (created if missing). Empty: no type. Unset: not managed.',
    },
    entity: {
      type: 'Optional[String]',
      desc: 'Complete name or unique name of the entity. Unset: not managed.',
    },
    entity_tag: {
      type: 'Optional[String]',
      desc: 'Tag of the entity (alternative to `entity`), compared case-sensitively. Unset: not managed.',
    },
    comment: {
      type: 'Optional[String]',
      desc: 'The comment, without the marker. Unset: the stored comment is kept.',
    },
    fields: {
      type: 'Hash[String[1], String]',
      desc: 'Custom fields by system name; only these keys are managed. Empty string: cleared. Default: no field is managed.',
      default: {},
    },
    field_refs: {
      type: "Hash[String[1], Enum['Computer', 'Appliance']]",
      desc: 'Fields of `fields` whose value is the name of an object of this itemtype (resolved to its id).',
      default: {},
      behaviour: :parameter,
    },
    delete_properties: {
      type: "Optional[Array[Enum['asset_type', 'comment']]]",
      desc: 'Optional properties to clear on update, by attribute name. Removing an attribute from the manifest only stops Puppet managing it. The marker stays in the GLPI comment.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_custom_asset)

# @api private
# entity and entity_tag both select the entity: only one may be declared.
# Hands the provider a resource's declared fields and field_refs before its
# current state is read, so get() reads only those fields.
module Puppet::Type::GlpiCustomAssetHooks
  # The RAL title is rebuilt as "<definition>/<name>" (see
  # GlpiCustomAssetTitle), so a catalog resource whose attributes disagree
  # with its title would lose the title relationships refer to: refused.
  def initialize(attributes)
    if attributes.is_a?(Puppet::Resource)
      values = attributes.to_hash
      expected = "#{values[:definition]}/#{values[:name]}"
      unless expected == attributes.title.to_s
        raise Puppet::ResourceError,
              "glpi_custom_asset[#{attributes.title}]: the title must be '<definition>/<name>' and agree with " \
              "the definition and name attributes (they give '#{expected}')"
      end
    end
    super
  end

  def validate
    super
    return unless self[:entity] && self[:entity_tag]

    raise Puppet::ResourceError, "glpi_custom_asset[#{title}]: entity and entity_tag are mutually exclusive"
  end

  def refresh_current_state
    if my_provider.respond_to?(:declare_fields)
      target = rsapi_canonicalized_target_state
      my_provider.declare_fields(rsapi_title, target[:fields], target[:field_refs])
    end
    super
  end
end

# @api private
# The Resource API builds the RAL resource from the attribute hash, whose
# title Puppet then takes from `name` alone: the same name in two
# definitions would be one title, a duplicate declaration. The RAL title is
# `<definition>/<name>` instead (the same key the provider uses).
module Puppet::Type::GlpiCustomAssetTitle
  def hash2resource(hash)
    attributes = hash.to_h { |key, value| [key.to_sym, value] }
    if !attributes.key?(:title) && attributes[:definition] && attributes[:name]
      attributes[:title] = "#{attributes[:definition]}/#{attributes[:name]}"
    end
    super(attributes)
  end
end

glpi_custom_asset_type = Puppet::Type.type(:glpi_custom_asset)
glpi_custom_asset_type.prepend(Puppet::Type::GlpiCustomAssetHooks) unless glpi_custom_asset_type.ancestors.include?(Puppet::Type::GlpiCustomAssetHooks)
unless glpi_custom_asset_type.singleton_class.ancestors.include?(Puppet::Type::GlpiCustomAssetTitle)
  glpi_custom_asset_type.singleton_class.prepend(Puppet::Type::GlpiCustomAssetTitle)
end
