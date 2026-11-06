# Changelog

All notable changes to this module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-11-06

Initial release.

### Added

- Supports Puppet 8 and 9 (tested on 8) on Debian 12 and 13, and GLPI 11 through its REST
  API v2 (OAuth2).
- `glpi` class that writes the API connection (`base_url`, OAuth client, service user,
  TLS settings) and the module's ownership settings to `<agent confdir>/glpi_transport.yaml`.
  The agent's confdir comes from the new `glpi_confdir` fact. Every `glpi_*` resource
  autorequires the file.
- `glpi::api_access` class for the GLPI server. It bootstraps what API v2 needs before any
  token exists (an OAuth client, a local service user and its profile assignment) by running
  a PHP script against GLPI's kernel, from a directory of its own (`config_dir`).
- Resource types: `glpi_rule`, `glpi_location`, `glpi_cluster`, `glpi_appliance`,
  `glpi_computer_placement`, `glpi_item_placement`, `glpi_config`, `glpi_custom_asset`,
  `glpi_certificate` and `glpi_domain`.
- Ownership by marker: only objects whose comment carries the marker (`marker`, overridable
  per type with `type_markers`) are ever deleted or purged, so objects created by hand are
  never touched. Removal moves objects to the trash.
- Purge guard that fails closed: `purge_max_fraction` and `purge_max_per_run` limit how many
  of a type's marked objects one run may delete, per guard scope.
- `unresolved` parameter that decides whether a reference matching no GLPI object only
  warns or fails the resource after everything else was applied.
- Names match case-insensitively and trashed objects are ignored everywhere. Where names are
  duplicated, the object carrying the marker is preferred and any other ambiguity fails the
  resource instead of guessing.
- One API connection and a write-through object cache are shared per Puppet process, and
  collections are paginated without relying on `Content-Range`.
- A created object that cannot be read back fails the resource instead of being created
  again on the next run.
- `glpi::resources`, which declares `glpi_*` resources from Hiera hashes and orders related
  entries.
- `delete_properties` clears optional properties on `glpi_appliance`, `glpi_certificate`,
  `glpi_cluster`, `glpi_custom_asset`, `glpi_domain` and `glpi_location`. The marker stays.
- URL, path and account parameters of the classes are type-checked (http(s) URLs, absolute
  paths, plain account names or numeric uids).

[Unreleased]: https://github.com/Data-JT/puppet-glpi/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Data-JT/puppet-glpi/releases/tag/v0.1.0
