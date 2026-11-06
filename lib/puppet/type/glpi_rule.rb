# frozen_string_literal: true

# rubocop:disable Layout/LineLength -- puppet-strings needs each desc and type as one literal

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_rule',
  docs: <<-EOS,
@summary Manages a GLPI rule (authorization, asset import or mail collector rule) through API v2.

Rules are matched by `name` across the supported collections, so a name must
be unique among the `right`, `import_asset` and `mail_collector` rules.

* An existing rule of the same name without the marker is adopted: it keeps
  its comment, gains the marker and is brought to the declared state. Unmarked
  rules of other names are never touched; purge sees only marked rules.
* `criteria` and `actions` compare as unordered sets. When they differ, all
  criteria (or actions) of the rule are replaced.
* An action whose `field` is `profiles_id` or `entities_id` may name the
  profile or entity (entity name or complete name) instead of its id.
* A new rule is created in the root entity (id 0), recursive, with
  condition 0; an adopted rule keeps its entity.

@example Authorization rule from an LDAP group
  glpi_rule { 'Staff rule':
    collection => 'right',
    criteria   => [{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'example-group' }],
    actions    => [
      { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Technician' },
      { 'action_type' => 'assign', 'field' => 'is_recursive', 'value' => '1' },
    ],
  }

@example Asset import rule ranked above another rule
  glpi_rule { 'Ignore lamps':
    collection  => 'import_asset',
    criteria    => [
      { 'criteria' => 'itemtype', 'condition' => 0, 'pattern' => 'Peripheral' },
      { 'criteria' => 'name', 'condition' => 6, 'pattern' => '/Lamp$/' },
    ],
    actions     => [{ 'action_type' => 'assign', 'field' => '_ignore_import', 'value' => '1' }],
    before_rule => 'Device update (by serial)',
  }
  EOS
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    ensure: {
      type: 'Enum[present, absent]',
      desc: 'Whether the rule should be present or absent.',
      default: 'present',
    },
    name: {
      type: 'String[1]',
      desc: 'The rule name (unique among the supported collections).',
      behaviour: :namevar,
    },
    collection: {
      type: "Enum['right', 'import_asset', 'mail_collector']",
      desc: 'The rule collection: authorizations (`right`), asset import (`import_asset`) or mail collector (`mail_collector`). A rule cannot move between collections.',
    },
    match: {
      type: "Enum['AND', 'OR']",
      desc: 'How the criteria combine.',
      default: 'AND',
    },
    is_active: {
      type: 'Boolean',
      desc: 'Whether the rule is active.',
      default: true,
    },
    criteria: {
      type: 'Array[Struct[{criteria => String[1], condition => Integer, pattern => String}]]',
      desc: 'The rule criteria. `condition` is a GLPI condition code, listed by `/Rule/Collection/<collection>/CriteriaCondition` (0 is, 2 contains, 6 regular expression matches, ...). Compared as an unordered set.',
    },
    actions: {
      type: 'Array[Struct[{action_type => String[1], field => String[1], value => String}]]',
      desc: 'The rule actions. For the fields `profiles_id` and `entities_id`, `value` may be a profile or entity name; it is read back as the name. Compared as an unordered set.',
    },
    before_rule: {
      type: 'Optional[String[1]]',
      desc: 'Name of a rule in the same collection this rule must rank above. In sync while this rule ranks above it; otherwise the rule is moved directly above it. (Named `before_rule` because `before` is a Puppet metaparameter.)',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_rule)
