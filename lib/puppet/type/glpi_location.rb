# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_location',
  docs: <<-EOS,
@summary Manages the comment of a GLPI location (dropdown) through API v2.

A location is identified by `name` AND `parent`: a location is matched only
among the children of `parent`, or among the top-level locations when no
parent is declared. The same name under another parent is a different
location, but two same-name locations under different parents cannot be
declared in one catalog (the rebuilt resource is titled by name alone, so
they collide as a duplicate declaration). A missing location is created,
never moved.

* `parent` is the parent's complete name: a top-level location by its name,
  a nested one as `Grandparent > Parent`; empty means top level.
* The title is the plain name of a top-level location, or `Parent > Name` for
  a nested one (`parent` and `name` are then taken from the title). A name
  must not contain ` > `.
* This is a match-and-update type: an existing location keeps everything the
  resource does not declare, is never marked and is never deleted.
  `ensure => absent` only logs a warning. Locations are not purged.
* Only `comment` is ever changed on an existing location. Removing `comment`
  from the manifest keeps the stored comment.
* `delete_properties => ['comment']` empties the stored comment.
* A new location is created in the root entity (id 0), recursive.
* Names and comments are compared after HTML-entity decoding and Unicode
  normalisation.

@example Location with a description
  glpi_location { 'Main office':
    comment => 'Head office',
  }

@example Location below another one
  glpi_location { 'Main office > North branch':
    comment => 'Branch office',
  }
  EOS
  title_patterns: [
    { pattern: %r{\A(?<parent>.+) > (?<name>[^>]+)\z}, desc: 'A title of the form "Parent > Name" names the parent and the location.' },
    { pattern: %r{\A(?<parent>)(?<name>.*)\z}m, desc: 'Any other title is the name of a top-level location.' },
  ],
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    ensure: {
      type: 'Enum[present, absent]',
      desc: 'Whether the location should exist. `absent` is a warning and changes nothing.',
      default: 'present',
    },
    name: {
      type: 'String[1]',
      desc: 'The location name (unique among the children of one parent).',
      behaviour: :namevar,
    },
    comment: {
      type: 'Optional[String]',
      desc: 'The location comment.',
    },
    parent: {
      type: 'String',
      desc: 'Complete name of the parent location (`A` or `A > B`). Empty (default): top level. Part of the identity.',
      default: '',
      behaviour: :namevar,
    },
    delete_properties: {
      type: "Optional[Array[Enum['comment']]]",
      desc: 'Optional properties to clear on update, by attribute name. Removing an attribute from the manifest only stops Puppet managing it.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_location)
