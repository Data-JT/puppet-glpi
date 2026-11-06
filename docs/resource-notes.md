# Resource notes

Behaviour of the `glpi_*` types that is not obvious from their attribute lists. The attributes
themselves are documented in [REFERENCE.md](../REFERENCE.md). Markers, adoption, the trash and
purge are described in [Markers, adoption and purge](markers-and-purge.md), missing references in
[Unresolved references](unresolved-references.md).

| Type | API v2 collection | Adoption | Deletes |
|---|---|---|---|
| `glpi_rule` | `/Rule/Collection/{right,import_asset,mail_collector}` | adopt | marked only |
| `glpi_cluster` | `/Management/Cluster` | skip unmarked | marked only |
| `glpi_appliance` | `/Management/Appliance`, links via GraphQL | skip unmarked | marked only |
| `glpi_custom_asset` | `/Assets/Custom/<definition>` | adopt | marked only |
| `glpi_certificate` | `/Management/Certificate`, links via GraphQL | adopt | marked only |
| `glpi_domain` | `/Management/Domain`, links via GraphQL | adopt | marked only |
| `glpi_location` | `/Dropdown/Location` (comment and parent) | match only | never |
| `glpi_computer_placement` | `/Assets/Computer` (entity, location) | no markers | never |
| `glpi_item_placement` | `/Assets/NetworkEquipment`, `/Management/DataCenter` (location) | no markers | never |
| `glpi_config` | `/Setup/Config/<context>/<key>` | no markers | never |

Every type that creates objects creates them in the root entity (id 0), recursive where API v2
allows it, unless an `entity` or `entity_tag` attribute says otherwise. `entity` takes an
entity's complete name (`Root entity > Customer A`) or a unique entity name; `entity_tag` selects
the entity whose tag equals it (tags compare case-sensitively) and the two are mutually exclusive.
Both read back as the complete name or the tag of the object's current entity, and compare by the
entity they resolve to. Unset, a new asset, certificate or domain gets the API user's default
entity. An unknown or ambiguous entity, tag or location fails the resource.

## glpi_rule

Authorization (`right`), asset import (`import_asset`) and mail collector (`mail_collector`)
rules.

```puppet
glpi_rule { 'Staff rule':
  collection => 'right',
  criteria   => [{ 'criteria' => 'memberof', 'condition' => 2, 'pattern' => 'example-group' }],
  actions    => [
    { 'action_type' => 'assign', 'field' => 'profiles_id', 'value' => 'Technician' },
    { 'action_type' => 'assign', 'field' => 'is_recursive', 'value' => '1' },
  ],
}

glpi_rule { 'Ignore lamps':
  collection  => 'import_asset',
  criteria    => [
    { 'criteria' => 'itemtype', 'condition' => 0, 'pattern' => 'Peripheral' },
    { 'criteria' => 'name', 'condition' => 6, 'pattern' => '/Lamp$/' },
  ],
  actions     => [{ 'action_type' => 'assign', 'field' => '_ignore_import', 'value' => '1' }],
  before_rule => 'Device update (by serial)',
}
```

- Rules are matched by name across the three collections, so a managed rule's name must be unique
  among them. A rule cannot move between collections.
- `condition` is GLPI's condition code, as listed by
  `GET /Rule/Collection/<collection>/CriteriaCondition` (0 is, 2 contains, 6 regular expression
  matches, ...). `match` (`AND`, default, or `OR`) says how the criteria combine; `is_active`
  defaults to `true`.
- `criteria` and `actions` compare as unordered sets. If they differ, all of the rule's criteria
  (or actions) are replaced.
- For the action fields `profiles_id` and `entities_id`, `value` may be the profile or entity name
  (or the entity's complete name). The name is resolved to the id on write and read back as the
  name. An unknown name fails the resource.
- `before_rule => '<rule name>'` keeps the rule ranked above another rule of the same collection.
  If the rule ranks below it, it is moved directly above it. The attribute is not called `before`
  because that name is a Puppet metaparameter.
- A new rule is created in the root entity, recursive, with condition 0. An existing rule of the
  same name without the marker is adopted: it keeps its comment and entity, and gains the marker.

## glpi_cluster

```puppet
glpi_cluster { 'Cluster A':
  cluster_type => 'Hypervisor',
  comment      => 'Three-node cluster',
}
```

- Matched by name among clusters that are not in the trash. A cluster of the same name without
  the marker is left alone, with a warning.
- The GLPI comment is the marker, a newline and `comment`; `comment` reads back without the
  marker. Unset, the stored comment is kept.
- A missing cluster type is created (root entity, recursive). An empty `cluster_type` means no
  type.
- Cluster membership is not managed: API v2 has no endpoint for it.
- API v2 does not expose `is_recursive` for clusters, so a new cluster gets GLPI's default.

## glpi_appliance

```puppet
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
```

- Matched by name among appliances that are not in the trash. An appliance of the same name
  without the marker is left alone, with a warning.
- `appliance_type` and `environment` name an appliance type and an appliance environment;
  missing ones are created. Empty means none.
- The resource owns only the links of the itemtypes in `member_types` (default `['Computer']`).
  It never reads, adds or removes links of other itemtypes, so links made by hand or by other
  tools coexist. Every itemtype in `members` must be listed in `member_types`. Members compare as
  an unordered set.
- A `Computer` member matches case-insensitively, or by its first DNS label when the full name
  matches no computer (agents may register short names). Other members match by exact name. A
  member that matches nothing is skipped with a warning, or fails the resource (see
  [Unresolved references](unresolved-references.md)).
- `Cluster` links can be compared but not changed: API v2 cannot link a cluster to an appliance.
  A needed change fails the resource and must be made in GLPI.
- The links are read through GLPI's GraphQL API, so the OAuth client needs the `graphql` scope
  (the `glpi::api_access` default).

`glpi_cluster` and `glpi_appliance` create new objects in the root entity. `ensure => absent` and
purge move a marked object to the trash. A trashed object is ignored: if its name is declared
again, a new object is created and the trashed one stays in the trash, unless `restore_trashed`
is set for the type.

## glpi_custom_asset

```puppet
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
```

- Identity is the asset definition's system name (the `<definition>` of
  `/Assets/Custom/<definition>`) and the name; the title is `<definition>/<name>` (a title
  without `/` fails, and so do `definition` or `name` attributes that disagree with the title;
  the name itself may contain `/`). The same name in two definitions is two resources.
- `fields` are custom fields by system name. Only declared keys are read, compared and written (a
  partial update leaves the other fields alone); `''` clears a field. Values compare as text, so
  a dropdown field is declared by the id GLPI stores (as a string) unless it is listed in
  `field_refs`.
- `field_refs` marks fields that hold an object id (`Computer`, `Appliance`, ...): declared as the
  object's name, written as its id, read back as its name. A `Computer` matches like
  `glpi_computer_placement` does. `''` means none. A name that matches nothing leaves the stored
  value alone with a warning, or fails the resource (see
  [Unresolved references](unresolved-references.md)); 0 is never written for it.
- `asset_type` is a value of the definition's type dropdown (`/Assets/Custom/<definition>Type`),
  created if missing; `''` means none. Unset `entity`/`entity_tag`: a new asset gets the API
  user's default entity.
- An unmarked asset of the same definition and name is adopted (a one-time change).
- Purge (`resources { 'glpi_custom_asset': purge => true }`) covers every definition GLPI lists
  under `/Assets/Custom/`. The purge guard counts per definition: the allowance of one definition
  is not spent by another.
- With `restore_trashed` (or `type_restore_trashed => { 'glpi_custom_asset' => true }`) a marked
  trashed asset of the same definition and name is restored instead of creating a new one.
- A link whose item is a custom asset cannot be written through API v2, so the module manages no
  such link; see [Known API gaps](api-gaps.md).

## glpi_certificate

```puppet
glpi_certificate { 'www.example.com':
  dns_name    => 'www.example.com',
  serial      => '04A1B2C3',
  expiration  => '2027-02-28',
  self_signed => false,
  entity      => 'Root entity > Customer A',
  computers   => ['web1.example.com'],
}
```

- Matched by name, case-insensitively (a common name in another case is the same certificate).
  An unmarked certificate of the same name is adopted.
- `dns_name`, `serial`, `expiration` (`YYYY-MM-DD`, `''` clears) and `self_signed` are managed
  when set; they are written as GLPI stores them (`dns_name`, `serial`, `date_expiration`,
  `is_selfsign`).
- `computers` are linked computers, matched like `glpi_computer_placement`. Only links to
  computers are read or written: links of the certificate to other item types are never touched.
  `computers_exclusive => false` adds missing links and never removes one. A computer that
  matches nothing is skipped with a warning, or fails the resource after the other links are
  written (see [Unresolved references](unresolved-references.md)).
- GLPI does not keep a link unique. Two rows of one certificate/computer pair read as one link; a
  declared pair keeps both rows, an undeclared pair (with `computers_exclusive`) loses all of
  them.
- A link row that GLPI returns without its certificate or computer id (typically the API user
  lacks the right to see it) fails the resource instead of reading as "no link".
- The links are read through GraphQL (the `graphql` scope). Links of a certificate to custom
  assets cannot be written through API v2 and are never read or touched. With `restore_trashed`
  a marked trashed certificate is restored instead of creating a new one.

## glpi_domain

```puppet
glpi_domain { 'example.com':
  expiration     => '2027-02-28',
  entity_tag     => '10001',
  contracts      => ['Hosting Customer A'],
  contract_scope => ['Hosting Customer A', 'Hosting Customer B'],
}
```

- Matched by name, case-insensitively; a new domain gets the name as declared (Unicode included,
  e.g. an IDN in its Unicode form). An unmarked domain of the same name is adopted. `expiration`
  reads back with a time of day in GLPI, which is ignored. GLPI's `is_active` flag is not
  managed.
- `contracts` are linked contracts by name. The resource only reads, adds and removes links to
  the contracts of `contract_scope` (unset: the contracts in `contracts`), so links to other
  contracts coexist. Declaring a contract outside a declared scope fails the resource. Moving a
  domain between two contracts of the scope links the new one first, then unlinks the old one.
- A contract name with no live match, or several, is unresolved (see
  [Unresolved references](unresolved-references.md)). While any declared contract is unresolved
  the resource removes no contract link at all (a typo must not strip the links that exist); the
  other links are still added.
- The links are read through GraphQL (the `graphql` scope). Links of a domain to custom assets
  cannot be written through API v2 and are never read or touched. With `restore_trashed` a marked
  trashed domain is restored instead of creating a new one.

## glpi_computer_placement

```puppet
glpi_computer_placement { 'web1.example.com':
  entity   => 'Root entity > Customers > Customer A',
  location => 'Main office',
}

glpi_computer_placement { 'db1.example.com':
  entity_tag => '10001',
}
```

- Update-only: places an existing computer, never creates, deletes or lists one. A computer that
  does not exist or is in the trash is a warning and counts as in sync, or fails the resource
  (see [Unresolved references](unresolved-references.md)).
- The title matches a computer case-insensitively, or by its first DNS label when the full name
  matches no computer. Two matches fail the resource.
- `entity` and `location` take a complete name (`A > B > C`) or a unique name, and read back as
  the complete name. They compare by the object they resolve to. An empty `location` means none.
- `entity_tag` selects the entity whose tag equals it, instead of `entity` (not both); tags
  compare case-sensitively. It reads back as the tag of the computer's current entity.
- Only declared attributes are written, and only when they differ. GLPI locks a field changed
  this way on an inventoried computer, so the next agent inventory keeps the value.
- An unknown or ambiguous entity, tag or location fails the resource.

## glpi_item_placement

```puppet
glpi_item_placement { 'NetworkEquipment/switch1':
  location => 'Main office > Server room',
}

glpi_item_placement { 'DataCenter/dc1':
  location => 'Main office',
}
```

- Update-only, like `glpi_computer_placement`: places an existing item, never creates, deletes or
  lists one. An item that does not exist or is in the trash is a warning and counts as in sync,
  or fails the resource (see [Unresolved references](unresolved-references.md)).
- The title is `<itemtype>/<name>`: `NetworkEquipment` or `DataCenter`. The same name under both
  itemtypes is two resources. The name matches one live item of that itemtype case-insensitively
  and exactly; two matches fail the resource, even with `unresolved => 'warn'` (an ambiguous name
  is not a missing reference).
- `location` takes a complete name or a unique name, reads back as the complete name and compares
  by the location it resolves to. An empty `location` means none; an unknown or ambiguous one
  fails the resource.
- GLPI locks a field changed this way on an inventoried device, so the next agent inventory keeps
  the value.

## glpi_location

```puppet
glpi_location { 'Main office':
  comment => 'Head office',
}

glpi_location { 'Main office > Branch':
  comment => 'Branch office',
}
```

- A location is identified by its name and parent. A top-level location uses its plain name as
  the title; a nested one uses `Parent > Name` (`parent` is the parent's complete name, `A` or
  `A > B`). A name must not contain ` > `. A missing location is created, never moved.
- Two locations that share a name but have different parents cannot be declared in one catalog:
  the title of the resource built from them is the plain name, so they collide as a duplicate
  declaration, whatever titles they are given. Declare only one of them.
- An existing location keeps everything the resource does not declare. Only `comment` is changed;
  the location is never marked, never deleted and never purged. `ensure => absent` only logs a
  warning. A missing one is created in the root entity, recursive.

## glpi_config

```puppet
glpi_config { 'inventory/stale_agents_delay':
  value => '14',
}
```

- Title is `<context>/<key>` (context `core` is the general setup, `inventory` the inventory
  settings); `value` is a string exactly as GLPI stores it (`'14'`, `'[2]'`, `'0'`). A number
  from the API reads back as its string.
- The key must exist. A write to an unknown key would create a new, meaningless row in GLPI, so
  the provider reads first and fails the resource instead. Keys are never listed, so there is no
  purge.
- Key names that look secret (`pass`, `secret`, `token`, `key`, `pwd`, `credential`) are refused
  by the type, so no such value is ever read, compared or logged. GLPI itself hides its mail and
  proxy passwords from this API; the inventory basic-auth password is not hidden, hence the name
  rule, which also refuses harmless keys such as `password_min_length`. The value appears in
  change events, so manage only non-secret settings.

## Ordering in glpi::resources

The resources class orders related entries declared in its Hiera hashes: a location before the
placements and the nested locations that name it, a rule's `before_rule` target before that rule.
Other references are left unconstrained, such as an appliance's members or objects declared
outside this class. Add `require` for those; otherwise a reference to an object that does not
exist yet stays unresolved until a later run.
