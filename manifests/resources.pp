# @summary Declares GLPI resources from Hiera data.
#
# Include this class after the main `glpi` class when you prefer data-driven
# resource declarations over inline glpi_* resource blocks. Every parameter
# defaults to `{}`, so including the class alone declares nothing.
#
# A reference that must exist before the resource it is named in can be
# applied is ordered when both are declared here: a nested location after its
# parent, a placement after its location, a rule after its `before_rule`. The
# other references (appliance members, custom asset `field_refs`) are resolved
# at run time as the types describe.
#
# @example Declare resources from Hiera
#   include glpi::resources
#
# @example Hiera data
#   glpi::resources::locations:
#     'Main office':
#       comment: 'Head office'
#     'Main office > Server room':
#       comment: 'Basement'
#   glpi::resources::clusters:
#     'Cluster A':
#       cluster_type: 'Hypervisor'
#   glpi::resources::appliances:
#     'Web shop':
#       appliance_type: 'Service'
#       members:
#         - { itemtype: 'Computer', name: 'web1.example.com' }
#   glpi::resources::computer_placements:
#     'web1.example.com':
#       location: 'Main office > Server room'
#   glpi::resources::item_placements:
#     'NetworkEquipment/switch1':
#       location: 'Main office > Server room'
#   glpi::resources::configs:
#     'inventory/stale_agents_delay':
#       value: '14'
#   glpi::resources::rules:
#     'Ignore lamps':
#       collection: 'import_asset'
#       criteria:
#         - { criteria: 'name', condition: 6, pattern: '/Lamp$/' }
#       actions:
#         - { action_type: 'assign', field: '_ignore_import', value: '1' }
#
# @param appliances
#   Hash of `glpi_appliance` resources, keyed by appliance name.
# @param certificates
#   Hash of `glpi_certificate` resources, keyed by certificate name.
# @param clusters
#   Hash of `glpi_cluster` resources, keyed by cluster name.
# @param computer_placements
#   Hash of `glpi_computer_placement` resources, keyed by computer name.
#   Ordered after the entry of `locations` their `location` names.
# @param configs
#   Hash of `glpi_config` resources, keyed as `<context>/<key>`.
# @param custom_assets
#   Hash of `glpi_custom_asset` resources, keyed as `<definition>/<name>`.
# @param domains
#   Hash of `glpi_domain` resources, keyed by domain name.
# @param item_placements
#   Hash of `glpi_item_placement` resources, keyed as `<itemtype>/<name>`.
#   Ordered after the entry of `locations` their `location` names.
# @param locations
#   Hash of `glpi_location` resources, keyed by name, or `Parent > Name` for a
#   nested location. A nested location is ordered after its parent's entry.
# @param rules
#   Hash of `glpi_rule` resources, keyed by rule name. A rule naming another
#   entry as its `before_rule` is ordered after it.
class glpi::resources (
  Hash[String, Hash] $appliances          = {},
  Hash[String, Hash] $certificates        = {},
  Hash[String, Hash] $clusters            = {},
  Hash[String, Hash] $computer_placements = {},
  Hash[String, Hash] $configs             = {},
  Hash[String, Hash] $custom_assets       = {},
  Hash[String, Hash] $domains             = {},
  Hash[String, Hash] $item_placements     = {},
  Hash[String, Hash] $locations           = {},
  Hash[String, Hash] $rules               = {},
) {
  $appliances.each |String $title, Hash $attributes| {
    glpi_appliance { $title:
      * => $attributes,
    }
  }

  $certificates.each |String $title, Hash $attributes| {
    glpi_certificate { $title:
      * => $attributes,
    }
  }

  $clusters.each |String $title, Hash $attributes| {
    glpi_cluster { $title:
      * => $attributes,
    }
  }

  $configs.each |String $title, Hash $attributes| {
    glpi_config { $title:
      * => $attributes,
    }
  }

  $custom_assets.each |String $title, Hash $attributes| {
    glpi_custom_asset { $title:
      * => $attributes,
    }
  }

  $domains.each |String $title, Hash $attributes| {
    glpi_domain { $title:
      * => $attributes,
    }
  }

  # Locations are ordered by complete name, the way the provider identifies
  # them: a parent's complete name is shorter than its child's, so this cannot
  # form a cycle. Keys are looked up rather than tested with `in`, which
  # ignores case and would order against a title that does not exist.
  $location_titles = $locations.reduce({}) |$memo, $entry| {
    $parent = $entry[1]['parent']
    $complete_name = ($entry[0] =~ / > / or $parent =~ Undef or $parent == '') ? {
      true    => $entry[0],
      default => "${parent} > ${entry[0]}",
    }
    $memo + { $complete_name => $entry[0] }
  }

  $location_titles.each |String $complete_name, String $title| {
    glpi_location { $title:
      * => $locations[$title],
    }
    $parent_name = $complete_name ? {
      /\A(.+) > /  => $1,
      default      => '',
    }
    if $location_titles[$parent_name] {
      Glpi_location[$location_titles[$parent_name]] -> Glpi_location[$title]
    }
  }

  $computer_placements.each |String $title, Hash $attributes| {
    glpi_computer_placement { $title:
      * => $attributes,
    }
    $location = $attributes['location']
    if $location and $location_titles[$location] {
      Glpi_location[$location_titles[$location]] -> Glpi_computer_placement[$title]
    }
  }

  $item_placements.each |String $title, Hash $attributes| {
    glpi_item_placement { $title:
      * => $attributes,
    }
    $location = $attributes['location']
    if $location and $location_titles[$location] {
      Glpi_location[$location_titles[$location]] -> Glpi_item_placement[$title]
    }
  }

  $rules.each |String $title, Hash $attributes| {
    glpi_rule { $title:
      * => $attributes,
    }
    $before = $attributes['before_rule']
    if $before and $before != $title and $rules[$before] {
      Glpi_rule[$before] -> Glpi_rule[$title]
    }
  }
}
