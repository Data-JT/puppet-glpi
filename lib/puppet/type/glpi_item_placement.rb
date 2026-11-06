# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_item_placement',
  docs: <<-EOS,
@summary Places an existing GLPI network device or data center in a location through API v2.

An update-only type: it never creates, deletes or lists items. An item
that does not exist (or is in the trash) is reported with a warning and
left alone; the resource is then in sync.

* The title is `<itemtype>/<name>`. `itemtype` is `NetworkEquipment`
  (`/Assets/NetworkEquipment`) or `DataCenter` (`/Management/DataCenter`);
  the same name under both itemtypes is two resources.
* The name matches a GLPI item of that itemtype case-insensitively and
  exactly; two live matches fail the resource.
* `location` is a location's complete name (`Main office > Branch`) or a
  unique location name; empty means no location. It reads back as the
  complete name and is compared by the location it resolves to.
* An unknown or ambiguous location fails the resource.
* The update goes through GLPI's normal update path: for an item that an
  inventory agent maintains, GLPI locks the changed field, so the next
  inventory keeps the value.

@example
  glpi_item_placement { 'NetworkEquipment/switch1':
    location => 'Main office > Server room',
  }

@example
  glpi_item_placement { 'DataCenter/dc1':
    location => 'Main office',
  }
  EOS
  features: ['simple_get_filter', 'custom_insync'],
  title_patterns: [
    { pattern: %r{\A(?<itemtype>[^/]+)/(?<name>.+)\z}m, desc: 'The title "ItemType/Name" names the item type and the item.' },
  ],
  attributes: {
    itemtype: {
      type: 'Enum["NetworkEquipment", "DataCenter"]',
      desc: 'The GLPI item type. Part of the identity.',
      behaviour: :namevar,
    },
    name: {
      type: 'String[1]',
      desc: 'The item name.',
      behaviour: :namevar,
    },
    location: {
      type: 'Optional[String]',
      desc: 'Complete name or unique name of the location. Empty: no location. Unset: not managed.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_item_placement)

# @api private
# The Resource API builds the RAL resource from the attribute hash, whose
# title Puppet then takes from `name` alone: the same name under two
# itemtypes would be one title, a duplicate declaration. The RAL title is
# `<itemtype>/<name>` instead (the same key the provider uses).
module Puppet::Type::GlpiItemPlacementTitle
  def hash2resource(hash)
    attributes = hash.to_h { |key, value| [key.to_sym, value] }
    if !attributes.key?(:title) && attributes[:itemtype] && attributes[:name]
      attributes[:title] = "#{attributes[:itemtype]}/#{attributes[:name]}"
    end
    super(attributes)
  end
end

glpi_item_placement_type = Puppet::Type.type(:glpi_item_placement)
unless glpi_item_placement_type.singleton_class.ancestors.include?(Puppet::Type::GlpiItemPlacementTitle)
  glpi_item_placement_type.singleton_class.prepend(Puppet::Type::GlpiItemPlacementTitle)
end
