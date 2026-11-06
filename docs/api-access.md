# API access

How the providers get into GLPI, and what `glpi::api_access` sets up on the GLPI server. The
generated parameter reference is in [REFERENCE.md](../REFERENCE.md#glpiapi_access); this page
adds the context around it.

GLPI 11 issues API v2 tokens only to an OAuth client, and a token is bound to a GLPI user. Neither
the client nor the user can be created through the API before such a token exists, so the class
creates them locally on the GLPI server: a PHP script boots GLPI's kernel as the GLPI system user
and makes the OAuth client, a local service user and the user's profile assignment match a JSON
config file. You can also create all three by hand in the GLPI UI and skip the class.

## The class

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

| Parameter | Type | Default | Description |
|---|---|---|---|
| `glpi_root` | `Stdlib::Absolutepath` | — | GLPI install directory, the one containing `vendor/autoload.php` |
| `system_user` | user name | `'glpi'` | System user that owns the GLPI files; the script runs as this user |
| `client_name` | `String[1]` | — | Display name of the OAuth client |
| `client_id` | `String[1]` | — | OAuth client identifier; the client is looked up by it |
| `client_secret` | `Sensitive[String[1]]` | — | OAuth client secret; GLPI stores it encrypted with its own key |
| `grants` | `Array[Enum['password', 'client_credentials']]` | `['password']` | OAuth grants the client may use |
| `scopes` | `Array[String[1]]` | `['api', 'graphql']` | OAuth scopes the client may request |
| `username` | `String[1]` | — | Login of the service user (GLPI local authentication) |
| `password` | `Sensitive[String[1]]` | — | Password of the service user; GLPI stores only its hash |
| `profile` | `String[1]` | `'Super-Admin'` | GLPI profile assigned to the service user |
| `entity_id` | `Integer[0]` | `0` | Entity the profile is assigned in (0 is the root entity) |
| `recursive` | `Boolean` | `true` | Whether the assignment applies to child entities |
| `config_dir` | `Stdlib::Absolutepath` | `'/etc/glpi-puppet'` | Directory of its own for the config file and the script |
| `php_binary` | `Stdlib::Absolutepath` | `'/usr/bin/php'` | PHP CLI binary that runs the script |

The script runs as `system_user` on every agent run in check mode (`unless`) and only changes GLPI
when the check reports a difference. Secrets are read from the config file only; they never appear
in a command line.

## The profile assignment

The providers see only what the service user's profile lets them see. Keep the assignment on the
root entity (`entity_id => 0`, the default) and recursive (the default): a profile on another
entity, or one that is not recursive, hides objects in other entities from the providers, and an
adopting type (see [Markers, adoption and purge](markers-and-purge.md)) could then create a
duplicate of an object it cannot see.

The class also sets the user's default profile. Without a default profile, API calls answer 403.

## Scopes

The providers request one token per scope from `<base_url>/token`. `api` covers every REST call.
`graphql` is needed to read the links of appliances, certificates and domains, which API v2 does
not list; it is requested only when one of those types is used. A client without the `graphql`
scope works for every other type.

## The bootstrap directory

`config_dir` holds the JSON config (`api-bootstrap.json`, mode 0600) and the script
(`glpi-api-bootstrap.php`). The class creates the directory and owns it (owner `system_user`,
mode 0700), so it must be a directory of its own: a top-level directory such as `/etc`, the GLPI
install directory, `/etc/glpi`, `/var/lib/glpi`, `/var/log/glpi` and anything below them are
refused at compile time. Nothing else in the directory is managed.

## Where the classes run

`glpi::api_access` belongs on the GLPI server, where PHP and the GLPI code are. The `glpi` class
and the `glpi_*` resources belong on whichever node should apply them; it needs HTTPS access to
GLPI, nothing more. The two can be the same node. See
[Class parameters](class-parameters.md) for the `glpi` class.
