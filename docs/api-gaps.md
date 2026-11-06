# Known API gaps

What GLPI's API v2 (as of GLPI 11.0) cannot do, and how the module reports or documents each gap
instead of working around it.

- **Cluster membership.** There is no endpoint, so `glpi_cluster` has no members.
- **Links to custom assets.** API v2 has no route to write any link whose item is a custom asset:
  a certificate, a domain, an appliance or a contract linked to a custom asset. GraphQL reads
  them (`Certificate_Item`, `Domain_Item`, `Appliance_Item`, `Contract_Item`), so the module can
  see such links but never creates or removes one. Make them in GLPI itself.
- **Appliance links of other itemtypes.** Links to `Cluster`, `Database` and custom assets can be
  read but not written. For writes, `member_types` is effectively `Computer` only; a needed
  change to another type fails the resource.
- **`is_recursive` of a new cluster** cannot be set; GLPI's default applies.
- **Rule names** must be unique across the three rule collections, because the name is the only
  key. Ranking works through `before_rule`, which sets the ranking.
- **Computer placement** is written through the API, which marks the fields as locked, so a later
  inventory keeps the value. The same applies to `glpi_item_placement`.
- **Custom asset and field definitions** cannot be read: there is no endpoint describing a
  definition's fields, so `glpi_custom_asset` cannot tell a dropdown field from a text field
  (hence `field_refs`) or check that a declared field exists.
- **Duplicate links.** A second link of the same certificate and computer is refused by the API
  (HTTP 500), but GLPI does not prevent duplicates made otherwise; see
  [Resource notes](resource-notes.md#glpi_certificate).
- **GraphQL** ignores variables and mis-reports `total_count` at an offset; the module uses
  literal arguments and pages until an empty page.
