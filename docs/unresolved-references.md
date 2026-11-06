# Unresolved references

What happens when a name in a resource matches nothing in GLPI, and how the `unresolved` class
parameter changes it.

The module resolves references by name when the provider runs. Some of them may legitimately be
missing for a while: an inventory agent has not registered a computer yet, a contract has not
been entered. These references are unresolved rather than wrong:

- the computer of a `glpi_computer_placement`, or the item of a `glpi_item_placement`, when it
  does not exist or is in the trash;
- a `glpi_appliance` member that matches nothing;
- a `glpi_custom_asset` reference field (`field_refs`) whose name matches nothing;
- a `glpi_certificate` computer that matches nothing;
- a `glpi_domain` contract that matches no live contract, or several.

Everything else that fails to resolve is an error and fails the resource: an unknown or ambiguous
entity, entity tag or location, a profile or entity name in a rule action, a dropdown value that
cannot be created, two live items for one `glpi_item_placement` name (an ambiguous name is not a
missing reference, so it fails even with `unresolved => 'warn'`).

## `warn` (default)

An unresolved reference is a warning, the resource counts as in sync and the rest of it is
written: an appliance's other members are linked and unlinked, a reference field keeps its stored
value (0 is never written for it). `glpi_domain` is more careful: while any declared contract is
unresolved the resource removes no contract link at all, so a typo cannot strip the links that
exist; the other links are still added.

## `fail`

```yaml
glpi::unresolved: fail
```

The resource still writes everything it can and then fails with the warning's text: the run's
report status is `failed` and `--detailed-exitcodes` sets bit 4. Only that resource fails;
resources that depend on it are skipped, as for any failure. While nothing else differs, a later
run writes nothing and records no change, only the failure again (one failure event for the
property, no `set`). A noop run reports that failure too; while links are still to be written,
noop shows only the change, since the failure comes after the write.

Use `fail` when a stale reference should show up in reports and monitoring, `warn` when the data
is expected to run ahead of the inventory.
