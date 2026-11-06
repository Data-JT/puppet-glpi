# @summary Bootstraps the OAuth client and service user the providers need for API v2.
#
# GLPI only issues API tokens to an OAuth client, and a token is bound to a
# user. Neither can be created through the API before such a token exists, so
# this class creates both locally: a PHP script boots the GLPI kernel and makes
# the OAuth client, the service user (local authentication) and the user's
# profile assignment match a JSON config file.
#
# The config file (`api-bootstrap.json`) and the script
# (`glpi-api-bootstrap.php`) live in `config_dir`. The class creates that
# directory and owns it (owner `system_user`, mode 0700), so it must be a
# directory of its own: a top-level directory (`/etc`), the GLPI install
# directory and the directories GLPI itself uses (`/etc/glpi`,
# `/var/lib/glpi`, `/var/log/glpi`) or anything below them are refused.
# Nothing else in the directory is managed.
#
# The script runs as `system_user` on every agent run in check mode (`unless`)
# and only changes GLPI when the check reports a difference. Secrets are read
# from the config file only; they never appear in a command line.
#
# @example Create the client and service user used by the providers
#   class { 'glpi::api_access':
#     glpi_root     => '/var/www/glpi',
#     client_name   => 'Puppet',
#     client_id     => 'puppet',
#     client_secret => Sensitive(lookup('glpi::client_secret')),
#     username      => 'puppet-api',
#     password      => Sensitive(lookup('glpi::api_password')),
#   }
#
# @param glpi_root
#   Absolute path of the GLPI install directory, the one containing
#   `vendor/autoload.php`.
# @param system_user
#   System user that owns the GLPI files; the script runs as this user. A user
#   name or a numeric uid.
# @param client_name
#   Display name of the OAuth client.
# @param client_id
#   OAuth client identifier (`client_id` in token requests). The client is
#   looked up by this value.
# @param client_secret
#   OAuth client secret. GLPI stores it encrypted with its GLPI key.
# @param grants
#   OAuth grants the client may use.
# @param scopes
#   OAuth scopes the client may request. The providers need `api`; glpi_appliance
#   also needs `graphql` (API v2 lists appliance links only through GraphQL).
# @param username
#   Login of the service user. It uses GLPI local authentication.
# @param password
#   Password of the service user. GLPI stores only its hash.
# @param profile
#   Name of the GLPI profile assigned to the service user.
# @param entity_id
#   ID of the entity the profile is assigned in.
# @param recursive
#   Whether the profile assignment applies to child entities.
# @param config_dir
#   Absolute path of a directory of its own for the config file and the
#   script, created and owned by this class (see above).
# @param php_binary
#   Absolute path of the PHP CLI binary used to run the script.
class glpi::api_access (
  Stdlib::Absolutepath                          $glpi_root,
  String[1]                                     $client_name,
  String[1]                                     $client_id,
  Sensitive[String[1]]                          $client_secret,
  String[1]                                     $username,
  Sensitive[String[1]]                          $password,
  Pattern[/\A[^\s\/:;\-][^\s\/:;]*\z/]         $system_user = 'glpi',
  Array[Enum['password', 'client_credentials']] $grants      = ['password'],
  Array[String[1]]                              $scopes      = ['api', 'graphql'],
  String[1]                                     $profile     = 'Super-Admin',
  Integer[0]                                    $entity_id   = 0,
  Boolean                                       $recursive   = true,
  Stdlib::Absolutepath                          $config_dir  = '/etc/glpi-puppet',
  Stdlib::Absolutepath                          $php_binary  = '/usr/bin/php',
) {
  $dir = regsubst($config_dir, '/+\z', '')
  if $dir !~ /\A\/[^\/]+\/./ {
    fail("glpi::api_access: config_dir '${config_dir}' must be a directory of its own at least two levels deep")
  }
  $glpi_dirs = [regsubst($glpi_root, '/+\z', ''), '/etc/glpi', '/var/lib/glpi', '/var/log/glpi']
  $glpi_dirs.each |$used| {
    if $dir == $used or $dir.stdlib::start_with("${used}/") {
      fail("glpi::api_access: config_dir '${config_dir}' is or lies in ${used}, a directory GLPI itself uses")
    }
  }
  $config_file = "${dir}/api-bootstrap.json"
  $script      = "${dir}/glpi-api-bootstrap.php"

  $config = {
    'glpi_root' => $glpi_root,
    'client'    => {
      'name'       => $client_name,
      'identifier' => $client_id,
      'secret'     => $client_secret.unwrap,
      'grants'     => $grants,
      'scopes'     => $scopes,
    },
    'user'      => {
      'name'     => $username,
      'password' => $password.unwrap,
    },
    'profile'   => {
      'name'      => $profile,
      'entity_id' => $entity_id,
      'recursive' => $recursive,
    },
  }

  file { $dir:
    ensure => directory,
    owner  => $system_user,
    mode   => '0700',
  }

  file { $config_file:
    ensure  => file,
    owner   => $system_user,
    mode    => '0600',
    content => Sensitive(stdlib::to_json_pretty($config)),
  }

  file { $script:
    ensure => file,
    owner  => 'root',
    group  => 'root',
    mode   => '0755',
    source => 'puppet:///modules/glpi/glpi-api-bootstrap.php',
  }

  $base = "${stdlib::shell_escape($php_binary)} ${stdlib::shell_escape($script)} --config ${stdlib::shell_escape($config_file)}"

  exec { 'glpi-api-bootstrap':
    command   => $base,
    unless    => "${base} --check",
    user      => $system_user,
    cwd       => $dir,
    logoutput => true,
    timeout   => 300,
    subscribe => [File[$config_file], File[$script]],
  }
}
