# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_cluster',
  docs: <<-EOS,
@summary Manages a GLPI cluster (Management > Clusters) through API v2.

Clusters are matched by `name` among the clusters that are not in the trash.

* An existing cluster of the same name without the marker is left alone: it
  is reported in sync with a warning and never changed, adopted or deleted.
* The marker is written first in the GLPI comment, followed by `comment`;
  `comment` reads back without it.
* `delete_properties` clears `cluster_type` or `comment`; the marker stays.
  An unmarked cluster is not written, so nothing is cleared on it.
* `cluster_type` names a cluster type; a missing type is created (root
  entity, recursive). An empty `cluster_type` means no type.
* A new cluster is created in the root entity (id 0). API v2 does not
  expose `is_recursive` for clusters, so GLPI's default applies.
* `ensure => absent` and purge move a marked cluster to the trash. A trashed
  cluster is invisible to this type: declaring its name again creates a new
  cluster, the trashed one is not restored.
* Cluster membership (which computers form the cluster) is not managed:
  API v2 has no endpoint for it.

@example
  glpi_cluster { 'Cluster A':
    cluster_type => 'Hypervisor',
    comment      => 'Three-node cluster',
  }
  EOS
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    ensure: {
      type: 'Enum[present, absent]',
      desc: 'Whether the cluster should be present or absent (absent moves it to the trash).',
      default: 'present',
    },
    name: {
      type: 'String[1]',
      desc: 'The cluster name.',
      behaviour: :namevar,
    },
    cluster_type: {
      type: 'Optional[String]',
      desc: 'Name of the cluster type (created if missing). Empty: no type. Unset: not managed.',
    },
    comment: {
      type: 'Optional[String]',
      desc: 'The comment, without the marker. Unset: the stored comment is kept.',
    },
    delete_properties: {
      type: "Optional[Array[Enum['cluster_type', 'comment']]]",
      desc: 'Optional properties to clear on update, by attribute name. Removing an attribute from the manifest only stops Puppet managing it. The marker stays in the GLPI comment.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_cluster)
