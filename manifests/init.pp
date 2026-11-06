# @summary Configures how the glpi_* resource providers reach the GLPI API.
#
# Writes a YAML file that the providers read at run time: the GLPI API v2
# connection (OAuth client and service user) and the module's ownership
# settings. Declare this class on the node that applies glpi_* resources.
# Every glpi_* resource autorequires the file, so on the first run it exists
# before any provider talks to GLPI.
#
# @example
#   class { 'glpi':
#     base_url      => 'https://glpi.example.com/api.php',
#     client_id     => 'puppet',
#     client_secret => Sensitive('...'),
#     username      => 'puppet-api',
#     password      => Sensitive('...'),
#   }
#
# @param base_url
#   GLPI API root, an http(s) URL, e.g. `https://glpi.example.com/api.php`. The
#   token endpoint is `<base_url>/token`, resources live under `<base_url>/v2/`.
# @param client_id
#   OAuth client id.
# @param client_secret
#   OAuth client secret.
# @param username
#   GLPI user the providers act as (password grant).
# @param password
#   Password of that user.
# @param grant_type
#   OAuth grant type.
# @param ssl_verify
#   Whether to verify the GLPI TLS certificate.
# @param ssl_ca_file
#   Absolute path of the CA bundle used for verification when GLPI uses a
#   private CA.
# @param marker
#   String in an object's comment that marks it as managed by Puppet. Only
#   marked objects are ever deleted or purged.
# @param type_markers
#   Per-type marker overrides, keyed by type name, e.g.
#   `{ 'glpi_cluster' => '[managed by puppet: clusters]' }`.
# @param purge_max_fraction
#   Largest share of a type's marked objects one run may delete. A run that
#   would delete more (at least one deletion is always allowed) fails every
#   deletion of that type and deletes nothing. 0 and 1 may be given as
#   integers; the file always holds a float.
# @param purge_max_per_run
#   Largest number of a type's marked objects one run may delete, whatever
#   the fraction allows (the smaller limit wins; per guard scope where a type
#   has scopes). It bounds what a run working from incomplete inputs (a
#   fact or data source that came back empty for part of the fleet) can
#   retire, which matters most when runs come often. 0: no absolute cap,
#   only the fraction applies.
# @param unresolved
#   What a reference that matches no GLPI object does: a
#   `glpi_computer_placement` whose computer does not exist (or is in the
#   trash), a `glpi_appliance` member that matches nothing. `warn` logs a
#   warning and reports the resource in sync. `fail` applies everything else
#   the resource declares and then fails the resource with the same message,
#   so the run reports a failure; nothing changes on later runs while the
#   reference stays unresolved, but each run reports the failure again.
# @param restore_trashed
#   When a resource's object exists only in the GLPI trash and carries the
#   marker, bring it back (with the resource's attributes) instead of
#   creating a second one. An unmarked trashed object is never restored.
# @param type_restore_trashed
#   Per-type override of `restore_trashed`, keyed by type name, e.g.
#   `{ 'glpi_cluster' => true }`.
# @param config_file
#   Absolute path of the transport file. It must be the path the agent's providers
#   read: `<agent confdir>/glpi_transport.yaml` (`Puppet[:confdir]` on the
#   node). The default is the agent's own confdir, from the `glpi_confdir`
#   fact; `$settings::confdir` (the COMPILING server's confdir, which differs
#   when server and agent use different layouts) only before that fact has
#   been pluginsynced.
class glpi (
  Pattern[/(?i:\Ahttps?:\/\/\S+\z)/]     $base_url,
  String[1]                              $client_id,
  Sensitive[String[1]]                   $client_secret,
  String[1]                              $username,
  Sensitive[String[1]]                   $password,
  Enum['password', 'client_credentials'] $grant_type           = 'password',
  Boolean                                $ssl_verify           = true,
  Optional[Stdlib::Absolutepath]         $ssl_ca_file          = undef,
  Pattern[/\S/]                          $marker               = '[managed by puppet]',
  Hash[String[1], Pattern[/\S/]]        $type_markers         = {},
  Variant[Float[0,1], Integer[0,1]]      $purge_max_fraction   = 0.5,
  Integer[0]                             $purge_max_per_run    = 3,
  Enum['warn', 'fail']                   $unresolved           = 'warn',
  Boolean                                $restore_trashed      = false,
  Hash[String[1], Boolean]               $type_restore_trashed = {},
  Stdlib::Absolutepath                   $config_file          = "${$facts['glpi_confdir'].lest || { $settings::confdir }}/glpi_transport.yaml",
) {
  $connection = {
    'base_url'      => $base_url,
    'client_id'     => $client_id,
    'client_secret' => $client_secret.unwrap,
    'username'      => $username,
    'password'      => $password.unwrap,
    'grant_type'    => $grant_type,
    'ssl_verify'    => $ssl_verify,
    'ssl_ca_file'   => $ssl_ca_file,
  }.filter |$key, $value| { $value =~ NotUndef }

  $module_settings = {
    'marker'               => $marker,
    'type_markers'         => $type_markers,
    'purge_max_fraction'   => Float($purge_max_fraction),
    'purge_max_per_run'    => $purge_max_per_run,
    'unresolved'           => $unresolved,
    'restore_trashed'      => $restore_trashed,
    'type_restore_trashed' => $type_restore_trashed,
  }

  # The providers read <agent confdir>/glpi_transport.yaml on the node; see
  # @param config_file.
  file { $config_file:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    content => Sensitive(epp('glpi/glpi_transport.epp', { 'config' => $connection + $module_settings })),
  }
}
