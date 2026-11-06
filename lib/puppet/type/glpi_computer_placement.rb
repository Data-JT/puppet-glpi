# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_computer_placement',
  docs: <<-EOS,
@summary Places an existing GLPI computer in an entity and a location through API v2.

An update-only type: it never creates, deletes or lists computers. A
computer that does not exist (or is in the trash) is reported with a
warning and left alone; the resource is then in sync.

* The title is the computer name. It matches a GLPI computer by name
  case-insensitively, or by the first DNS label of the name when the full
  name matches nothing (agents may register short names). Two matches fail
  the resource.
* `entity` is an entity's complete name (`Root entity > Customers > Customer A`)
  or a unique entity name. It reads back as the complete name; values are
  compared by the entity they resolve to.
* `entity_tag` selects the entity whose tag equals it (it must be unique)
  instead of `entity`; the two are mutually exclusive. Tags compare
  case-sensitively. It reads back as the tag of the computer's current
  entity.
* `location` is a location's complete name (`Main office > Branch`) or a
  unique location name; empty means no location. Compared like `entity`.
* Only the declared attributes are written, and only when they differ.
  The update goes through GLPI's normal update path: for a computer that
  an inventory agent maintains, GLPI locks the changed fields, so the next
  inventory keeps the value.
* An unknown or ambiguous entity, entity tag or location fails the resource.

@example
  glpi_computer_placement { 'web1.example.com':
    entity   => 'Root entity > Customers > Customer A',
    location => 'Main office',
  }

@example Entity by its tag
  glpi_computer_placement { 'db1.example.com':
    entity_tag => '10001',
  }
  EOS
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    name: {
      type: 'String[1]',
      desc: 'The computer name.',
      behaviour: :namevar,
    },
    entity: {
      type: 'Optional[String[1]]',
      desc: 'Complete name or unique name of the entity. Unset: not managed.',
    },
    entity_tag: {
      type: 'Optional[String[1]]',
      desc: 'Tag of the entity (alternative to `entity`), compared case-sensitively. Unset: not managed.',
    },
    location: {
      type: 'Optional[String]',
      desc: 'Complete name or unique name of the location. Empty: no location. Unset: not managed.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_computer_placement)

# @api private
# entity and entity_tag both select the entity: only one may be declared.
module Puppet::Type::GlpiComputerPlacementValidation
  def validate
    super
    return unless self[:entity] && self[:entity_tag]

    raise Puppet::ResourceError, "glpi_computer_placement[#{title}]: entity and entity_tag are mutually exclusive"
  end
end

glpi_computer_placement_type = Puppet::Type.type(:glpi_computer_placement)
unless glpi_computer_placement_type.ancestors.include?(Puppet::Type::GlpiComputerPlacementValidation)
  glpi_computer_placement_type.prepend(Puppet::Type::GlpiComputerPlacementValidation)
end
