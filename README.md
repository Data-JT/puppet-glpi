<a href="https://www.data-jt.de">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/Data-JT/.github/main/profile/banner-dark.svg">
    <img alt="Data JT" src="https://raw.githubusercontent.com/Data-JT/.github/main/profile/banner-light.svg" width="420">
  </picture>
</a>

# datajt-glpi

Manage GLPI inventory objects as Puppet code, through the GLPI REST API v2.

## Table of contents

1. [Description](#description)
2. [Requirements](#requirements)
3. [Quick start](#quick-start)
4. [Resource types and classes](#resource-types-and-classes)
5. [Further documentation](#further-documentation)
6. [Limitations](#limitations)
7. [Contributing](#contributing)
8. [License](#license)
9. [About Data JT](#about-data-jt)

## Description

This module lets you describe objects of a [GLPI](https://glpi-project.org/) 11 instance in
Puppet code or Hiera: rules, clusters, appliances and their members, custom assets and their
fields, certificates, domains and their links, locations, the placement of inventoried computers
and network devices, and configuration values. The Puppet agent compares that description with
what GLPI stores and changes only what differs.

### What it does

- Manages 10 kinds of GLPI objects as native Puppet resource types (`glpi_*`), over the GLPI
  REST API v2 (plus GraphQL where API v2 cannot list a link).
- Declares all of them from Hiera through one class, `glpi::resources`.
- Resolves references by name (an entity, a location, a computer, a contract, a profile), so the
  data needs no GLPI ids for them.
- Marks every object it creates (default `[managed by puppet]` in the comment) and deletes only
  marked objects; a marked object in the GLPI trash can be restored instead of recreated.
- Bootstraps what API v2 needs on the GLPI server (OAuth client, service user, profile) through
  `glpi::api_access`, since GLPI cannot create these through the API.

### What it does not do

- It does not install GLPI, its database or its web server. It configures an existing GLPI.
- It does not create inventory: computers, network devices and data centers come from GLPI's
  agents; the placement types only move existing ones.
- It does not use the legacy `apirest.php` API, `puppet device`, a proxy agent or a Bolt
  transport. The agent runs on any node that reaches the API over HTTPS.
- It does not purge, delete or adopt objects without the marker, and it never restores an
  unmarked object from the trash.
- It does not clear a value when you remove an attribute; use `delete_properties` for that.
- It cannot manage cluster membership or links to custom assets: API v2 has no endpoint for them.

### How it works

```text
On the GLPI server, once:

glpi::api_access   creates the OAuth client and the service user in GLPI

On the node that manages GLPI, every agent run:

Hiera / manifest   declares the class and the resources
      │
      ▼
glpi class         writes glpi_transport.yaml (URL, OAuth client, service user, 0600)
      │
      ▼
glpi_* types       read that file and fetch an OAuth token
      │
      ▼
GLPI API v2        https://glpi.example.com/api.php (GraphQL for links)
```

The `glpi` class writes the API connection and the module's ownership settings (marker, purge
guard, unresolved references, trash restore) to a transport file in the agent's confdir. The
`glpi_*` types are built on the Puppet Resource API; their providers read that file, fetch an
OAuth token from `<base_url>/token` and compare or change objects on every agent run. Resources
come from manifests or from Hiera via `glpi::resources`.

## Requirements

- Puppet or OpenVox 8 or 9 (`>= 8.0.0 < 10.0.0`). Testing is currently done on 8 (CI and production); on 9 the unit tests also run in CI
  (OpenVox 9.3), but there is no production use yet. Forge dependency: `puppetlabs/stdlib`.
- GLPI 11 with API v2 enabled. The legacy `apirest.php` API is not used.
- Debian 12 or 13.
- An OAuth client and a service user with a recursive profile on the root entity;
  `glpi::api_access` creates them.

## Quick start

### 1. Prepare GLPI

On the GLPI server, declare `glpi::api_access`. A PHP script that boots GLPI's kernel creates the
OAuth client (scopes `api` and `graphql`), the local service user and its profile assignment
(`Super-Admin` on the root entity, recursive), and sets the user's default profile:

```puppet
class { 'glpi::api_access':
  glpi_root     => '/var/www/glpi',
  client_name   => 'Puppet',
  client_id     => 'puppet',
  client_secret => Sensitive(lookup('glpi::client_secret')),
  username      => 'puppet-api',
  password      => Sensitive(lookup('glpi::password')),
}
```

Keep the assignment on the root entity and recursive; anything narrower hides objects from the
providers. See [API access](https://github.com/Data-JT/puppet-glpi/blob/master/docs/api-access.md).

### 2. Manifest

```puppet
# site/profile/manifests/glpi.pp
class profile::glpi {
  include glpi            # transport: base_url, OAuth client and service user from Hiera
  include glpi::resources # glpi_* resources from Hiera

  # Resources can also be declared directly:
  glpi_computer_placement { 'web1.example.com':
    entity   => 'Root entity > Customers > Customer A',
    location => 'Main office',
  }
}
```

### 3. Hiera

```yaml
# Class parameters. Keep the secrets encrypted (hiera-eyaml) and convert them to Sensitive.
lookup_options:
  glpi::client_secret:
    convert_to: Sensitive
  glpi::password:
    convert_to: Sensitive

glpi::base_url: https://glpi.example.com/api.php
glpi::client_id: puppet
glpi::client_secret: ENC[PKCS7,...]
glpi::username: puppet-api
glpi::password: ENC[PKCS7,...]
glpi::ssl_ca_file: /etc/ssl/certs/example-ca.pem  # when GLPI uses a private CA

# Resources
glpi::resources::locations:
  'Main office':
    comment: Head office

glpi::resources::appliances:
  'Web shop':
    appliance_type: Service
    environment: Production
    members:
      - itemtype: Computer
        name: web1.example.com

glpi::resources::computer_placements:
  web1.example.com:
    entity: Root entity > Customers > Customer A
    location: Main office

glpi::resources::rules:
  'Staff rule':
    collection: right
    criteria:
      - { criteria: memberof, condition: 2, pattern: example-group }
    actions:
      - { action_type: assign, field: profiles_id, value: Technician }

glpi::resources::configs:
  inventory/stale_agents_delay:
    value: '14'
```

`ensure` defaults to `present`. References are resolved by name against GLPI when the provider
runs; the resources class orders locations before the placements and nested locations that name
them, and a rule after its `before_rule`. For other references, such as an appliance's members,
use `require`, or they resolve on the next run.
Custom assets, certificates, domains and item placements work the same way; see the docs pages
below. Run the first pass with `puppet agent -t --noop`.

## Resource types and classes

| Type | Manages | Unmarked object of that name |
|---|---|---|
| `glpi_rule` | Authorization, asset import and mail collector rules, with ranking | adopted |
| `glpi_cluster` | Clusters (name, type, comment) | left alone, with a warning |
| `glpi_appliance` | Appliances and their member links | left alone, with a warning |
| `glpi_custom_asset` | Assets of any custom asset definition and their custom fields | adopted |
| `glpi_certificate` | Certificates and their links to computers | adopted |
| `glpi_domain` | Domains and their links to contracts | adopted |
| `glpi_location` | The comment of a location (created if missing) | updated, never marked or deleted |
| `glpi_computer_placement` | Entity and location of an existing computer | update-only, no marker |
| `glpi_item_placement` | Location of an existing network device or data center | update-only, no marker |
| `glpi_config` | An existing configuration value (`<context>/<key>`) | update-only, no marker |

Classes: `glpi` (the transport file and ownership settings), `glpi::resources` (the `glpi_*`
resources from Hiera) and `glpi::api_access` (OAuth client, service user and profile on the GLPI
server). Every attribute and parameter is documented in
[REFERENCE.md](https://github.com/Data-JT/puppet-glpi/blob/master/REFERENCE.md).

## Further documentation

- [API access](https://github.com/Data-JT/puppet-glpi/blob/master/docs/api-access.md): `glpi::api_access`, the profile assignment, scopes, the bootstrap directory.
- [Class parameters](https://github.com/Data-JT/puppet-glpi/blob/master/docs/class-parameters.md): the `glpi` class, tokens and TLS, the transport file.
- [Markers, adoption and purge](https://github.com/Data-JT/puppet-glpi/blob/master/docs/markers-and-purge.md): the marker, adoption policies, name matching, duplicates, the trash, the purge guard.
- [Unresolved references](https://github.com/Data-JT/puppet-glpi/blob/master/docs/unresolved-references.md): what a name that matches nothing does, `warn` versus `fail`.
- [Resource notes](https://github.com/Data-JT/puppet-glpi/blob/master/docs/resource-notes.md): every type in detail, with examples.
- [Clearing optional properties](https://github.com/Data-JT/puppet-glpi/blob/master/docs/clearing-properties.md): removing a value in GLPI with `delete_properties`.
- [Known API gaps](https://github.com/Data-JT/puppet-glpi/blob/master/docs/api-gaps.md): what API v2 cannot do and how the module reports it.

## Limitations

- A run deletes at most `purge_max_per_run` (default 3) and at most half of a type's marked
  objects; a larger cleanup takes several runs or a raised cap. Noop does not show the guard.
- Rule names must be unique across the three rule collections, and two `glpi_location` resources
  with the same name under different parents cannot be declared in one catalog.
- `glpi_cluster` has no members and `glpi_appliance` cannot change links to clusters or custom
  assets; API v2 has no endpoint for them.
- `glpi_config` refuses keys whose name looks like a secret; values appear in change events.
- A service user whose profile does not cover the root entity recursively cannot see every
  object, and an adopting type could then create a duplicate of one it cannot see.

## Contributing

Issues and pull requests are welcome on
[GitHub](https://github.com/Data-JT/puppet-glpi/issues); please open an issue before
significant work. See [CONTRIBUTING.md](https://github.com/Data-JT/puppet-glpi/blob/master/CONTRIBUTING.md)
for the development workflow and [SECURITY.md](https://github.com/Data-JT/puppet-glpi/blob/master/SECURITY.md)
for reporting vulnerabilities.

## License

Apache-2.0, see [LICENSE](https://github.com/Data-JT/puppet-glpi/blob/master/LICENSE).

## About Data JT

This module is built and maintained by [Data JT](https://www.data-jt.de), an IT and data
protection consultancy near Freiburg, Germany. All our modules are on the
[Puppet Forge](https://forge.puppet.com/modules/datajt). For anything beyond issues and pull
requests, [get in touch](https://www.data-jt.de/kontakt).
