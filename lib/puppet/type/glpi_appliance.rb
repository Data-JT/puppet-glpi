# frozen_string_literal: true

# rubocop:disable Layout/LineLength -- puppet-strings needs each desc and type as one literal

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

# The itemtype Enum below must be kept in step with
# Puppet::Provider::GlpiAppliance::GlpiAppliance::ITEMTYPES. It is written out
# because puppet-strings cannot document interpolated type strings.
Puppet::ResourceApi.register_type(
  name: 'glpi_appliance',
  docs: <<-EOS,
@summary Manages a GLPI appliance and its member links through API v2.

Appliances are matched by `name` among the appliances that are not in the
trash.

* An existing appliance of the same name without the marker is left alone:
  it is reported in sync with a warning and never changed, adopted or
  deleted.
* The marker is written first in the GLPI comment, followed by `comment`;
  `comment` reads back without it.
* `delete_properties` clears `appliance_type`, `comment` or `environment`;
  the marker stays. An unmarked appliance is not written, so nothing is
  cleared on it.
* `appliance_type` and `environment` name an appliance type and an
  appliance environment; missing ones are created. Empty means none.
* `members` are the items linked to the appliance, by itemtype and name.
  The resource is authoritative only for the itemtypes in `member_types`:
  links of other itemtypes are never read, added or removed, so links made
  by hand or by other tools coexist. Members compare as an unordered set.
* A `Computer` member matches a GLPI computer by name case-insensitively,
  or by the first DNS label of the name when the full name matches nothing
  (agents may register short names). Other members match by exact name.
  A member that matches nothing is skipped with a warning.
* `Cluster` members can be read and compared, but API v2 cannot add or
  remove a cluster link: a needed change fails the resource and must be
  made in GLPI.
* Reading the links uses the GLPI GraphQL API: the OAuth client needs the
  `graphql` scope in addition to `api` (see `glpi::api_access`).
* A new appliance is created in the root entity (id 0), recursive.
* `ensure => absent` and purge move a marked appliance to the trash. A
  trashed appliance is invisible to this type: declaring its name again
  creates a new appliance, the trashed one is not restored.

@example
  glpi_appliance { 'Web shop':
    appliance_type => 'Service',
    environment    => 'Production',
    comment        => 'Shop and blog',
    member_types   => ['Computer', 'Cluster'],
    members        => [
      { 'itemtype' => 'Computer', 'name' => 'web1.example.com' },
      { 'itemtype' => 'Cluster', 'name' => 'Cluster A' },
    ],
  }
  EOS
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    ensure: {
      type: 'Enum[present, absent]',
      desc: 'Whether the appliance should be present or absent (absent moves it to the trash).',
      default: 'present',
    },
    name: {
      type: 'String[1]',
      desc: 'The appliance name.',
      behaviour: :namevar,
    },
    appliance_type: {
      type: 'Optional[String]',
      desc: 'Name of the appliance type (created if missing). Empty: no type. Unset: not managed.',
    },
    environment: {
      type: 'Optional[String]',
      desc: 'Name of the appliance environment (created if missing). Empty: none. Unset: not managed.',
    },
    comment: {
      type: 'Optional[String]',
      desc: 'The comment, without the marker. Unset: the stored comment is kept.',
    },
    members: {
      type: "Optional[Array[Struct[{itemtype => Enum['Computer', 'Monitor', 'NetworkEquipment', 'Peripheral', 'Phone', 'Printer', 'SoftwareLicense', 'Certificate', 'Unmanaged', 'Appliance', 'Cluster'], name => String[1]}]]]",
      desc: 'Items linked to the appliance. Every itemtype must be listed in `member_types`. Compared as an unordered set. Unset: links are not managed.',
    },
    member_types: {
      type: "Array[Enum['Computer', 'Monitor', 'NetworkEquipment', 'Peripheral', 'Phone', 'Printer', 'SoftwareLicense', 'Certificate', 'Unmanaged', 'Appliance', 'Cluster'], 1]",
      desc: 'The itemtypes this resource is authoritative for. Links of other itemtypes are ignored.',
      default: ['Computer'],
      behaviour: :parameter,
    },
    delete_properties: {
      type: "Optional[Array[Enum['appliance_type', 'comment', 'environment']]]",
      desc: 'Optional properties to clear on update, by attribute name. Removing an attribute from the manifest only stops Puppet managing it. The marker stays in the GLPI comment.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_appliance)

# @api private
# Hands the provider a resource's member_types before its current state is
# read, so get() reads only the links of those itemtypes.
module Puppet::Type::GlpiApplianceMemberTypes
  def refresh_current_state
    my_provider.declare_member_types(rsapi_title, self[:member_types]) if my_provider.respond_to?(:declare_member_types)
    super
  end
end

glpi_appliance_type = Puppet::Type.type(:glpi_appliance)
glpi_appliance_type.prepend(Puppet::Type::GlpiApplianceMemberTypes) unless glpi_appliance_type.ancestors.include?(Puppet::Type::GlpiApplianceMemberTypes)
