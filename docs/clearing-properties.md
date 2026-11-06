# Clearing optional properties

How to remove a value in GLPI, since removing an attribute from a manifest does not.

Removing an attribute from a manifest only stops Puppet comparing it, so the removal alone never
changes anything in GLPI. To clear an optional property, list its attribute name in
`delete_properties`:

```puppet
glpi_certificate { 'www.example.com':
  dns_name          => 'www.example.com',
  delete_properties => ['serial', 'expiration'],
}
```

API v2 has no delete parameter, so the provider writes the field empty on update, which is how it
already writes an unset value. It does so only while one of the named properties is still set, so
the resource converges instead of re-sending the change on every run. Declaring a value for an
attribute that is also listed fails the resource, because it could never converge. Create requests
never need it. The clearing also applies when an object is adopted or restored, because both
are writes to an existing object.

Each type accepts only the attributes its provider can clear:

| Type | Clearable attributes |
|---|---|
| `glpi_cluster` | `comment`, `cluster_type` |
| `glpi_appliance` | `comment`, `appliance_type`, `environment` |
| `glpi_custom_asset` | `comment`, `asset_type` |
| `glpi_certificate` | `comment`, `dns_name`, `serial`, `expiration` |
| `glpi_domain` | `comment`, `expiration` |
| `glpi_location` | `comment` |

Clearing `comment` removes the resource's text; the marker stays, so the object remains managed.

## Already clearable by value

Some attributes also clear through an empty string: `''` for `cluster_type`, `appliance_type`,
`environment`, `asset_type` and `expiration` means none, `''` for `location` on `glpi_computer_placement` and
`glpi_item_placement` means no location, and `''` in a `glpi_custom_asset` field or `field_refs`
value clears that field. An attribute whose empty value already means "none" needs no entry in
`delete_properties`.

## Not clearable

- `entity` and `entity_tag`: every object belongs to an entity; move it instead.
- A rule's `criteria` and `actions`: declare the wanted set, which replaces the stored one.
- `members`, `computers` and `contracts`: declare an empty array to remove the links the resource
  is authoritative for (`member_types`, `computers_exclusive`, `contract_scope`).
- `glpi_config` values: the key must keep a value; set the one you want.
