# Markers, adoption and purge

How the module tells its own objects from everything else in GLPI, and what that means for
existing objects, duplicates, the trash and `resources { purge => true }`.

## The marker

Objects Puppet creates carry a marker in their `comment`: the class parameter `marker` (default
`[managed by puppet]`), overridable per type with `type_markers`. The marker is written first in
the GLPI comment, followed by the resource's `comment`; `comment` reads back without it. For a
type without a comment attribute (`glpi_rule`) the stored comment is kept and the marker appended.

Deleting and purging only ever touch marked objects. `ensure => absent` on an unmarked object is
reported in sync with a warning, and the provider refuses the deletion as a second line of
defence. Marked objects of the deleting types (`glpi_rule`, `glpi_cluster`, `glpi_appliance`,
`glpi_custom_asset`, `glpi_certificate`, `glpi_domain`) are moved to the GLPI trash, not purged
from the database.

## Adoption

Adoption decides what happens to an existing, unmarked object whose name is declared:

| Policy | Types | Effect |
|---|---|---|
| adopt | `glpi_rule`, `glpi_custom_asset`, `glpi_certificate`, `glpi_domain` | The object is taken over, brought to the declared state and gains the marker. It keeps its comment and entity. In noop mode this shows once as a create. |
| skip unmarked | `glpi_cluster`, `glpi_appliance` | The object is reported in sync with a warning and never changed, adopted or deleted. |
| match only | `glpi_location` | The object is matched and updated, never marked, never deleted. |
| no markers | `glpi_computer_placement`, `glpi_item_placement`, `glpi_config` | Update-only: the type changes objects that already exist and never creates or deletes one. |

## Name matching

Names are matched case-insensitively. GLPI compares names without regard to case and its UI lets
users change the case freely, so the module does the same: `Foo` in a manifest matches `foo` in
GLPI, in every type. A location also compares its parent that way, and so do dropdown values
such as a cluster type or a rule's profile. Names are compared after HTML-entity decoding and
Unicode normalisation. A case-only difference is in sync; the name in GLPI is not rewritten (a
`glpi_rule` keeps its name even when it is written for another reason). Comments and other
properties still compare case-sensitively. If two objects of a type differ from the declared name
only in case, the resource fails with their ids, like any other ambiguous match.

## Duplicate names

When several live objects share a declared name and exactly one of them carries the marker, that
one is the managed object: it is written, compared and (if absent) deleted, and the unmarked ones
are left alone, which an info message says once per run with their ids. This covers, for example,
a domain that GLPI's own inventory created a second time in another entity. If none or more than
one of them carries the marker, the resource fails with the ids; so does `glpi_location`, which
uses no marker.

Names used as references (an appliance member, a location's parent, a dropdown value) must still
be unique: any duplicate there fails the resource.

## The trash

Objects in the GLPI trash are ignored by every type: never matched, adopted or purged. If a
trashed object has the declared name, a new object is created and a warning says the trashed one
stays in the trash.

The exception is `restore_trashed` (class `glpi`, or `type_restore_trashed` per type): a trashed
object that carries the marker is restored, with the resource's attributes, instead of creating a
second one, and managed from there. A trashed object without the marker is never restored; two
marked trashed objects of the same name fail the resource.

```yaml
glpi::restore_trashed: false
glpi::type_restore_trashed:
  glpi_custom_asset: true
```

## Purge

`resources { 'glpi_rule': purge => true }` lists only marked objects that no resource declares,
so unmarked objects are never offered for deletion. An object whose name differs from a declared
one only in case is the declared object: it is not offered for purge and shows no change (should
a removal for it ever reach the provider, it is refused with a warning).

`glpi_location`, `glpi_computer_placement`, `glpi_item_placement` and `glpi_config` are never
purged. `glpi_custom_asset` purge covers every definition GLPI lists under `/Assets/Custom/`.

## The purge guard

A run may delete at most `max(1, floor(f x managed))` objects per type, where `f` is
`purge_max_fraction` (default 0.5) and `managed` the number of marked objects of that type, and
never more than `purge_max_per_run` (default 3; 0 switches this cap off). The cap bounds what a
run with incomplete inputs can retire: a fact that came back empty on one node takes that node's
objects out of the catalog, and with frequent runs a fraction alone would let such a gap retire a
large type within hours.

If a run would delete more, nothing of that type is deleted and the resources fail; a bigger
cleanup takes several runs or a raised cap. The `managed` count is taken before the run's first
write of the type, so creates and adoptions earlier in the same run do not raise the allowance.
The guard is not visible in noop mode: noop never reaches the step that refuses, so the refusal
only appears in the real run.

`glpi_custom_asset` counts per asset definition: each definition has its own `managed` count and
allowance, and a pending deletion counts in the definition of the object it names. The allowance
of one definition is not spent by another.
