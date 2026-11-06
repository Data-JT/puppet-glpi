# Class parameters

The `glpi` class configures how the providers reach the GLPI API and how the module treats the
objects it manages. The generated parameter reference is in [REFERENCE.md](../REFERENCE.md#glpi);
this page adds the context around it.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `base_url` | http(s) URL | — | GLPI API root, e.g. `https://glpi.example.com/api.php`; tokens come from `<base_url>/token`, resources live under `<base_url>/v2/` |
| `client_id` | `String[1]` | — | OAuth client id |
| `client_secret` | `Sensitive[String[1]]` | — | OAuth client secret |
| `username` | `String[1]` | — | GLPI user the providers act as (password grant) |
| `password` | `Sensitive[String[1]]` | — | Password of that user |
| `grant_type` | `Enum['password', 'client_credentials']` | `'password'` | OAuth grant type |
| `ssl_verify` | `Boolean` | `true` | Verify the GLPI TLS certificate |
| `ssl_ca_file` | `Optional[Stdlib::Absolutepath]` | `undef` | CA bundle used for verification when GLPI uses a private CA |
| `marker` | non-blank string | `'[managed by puppet]'` | String in an object's comment that marks it as managed by Puppet |
| `type_markers` | `Hash` of non-blank strings | `{}` | Per-type marker overrides, keyed by type name |
| `purge_max_fraction` | `Variant[Float[0,1], Integer[0,1]]` | `0.5` | Largest share of a type's marked objects one run may delete |
| `purge_max_per_run` | `Integer[0]` | `3` | Largest number of a type's marked objects one run may delete; 0 switches the cap off |
| `unresolved` | `Enum['warn', 'fail']` | `'warn'` | What a reference that matches no GLPI object does |
| `restore_trashed` | `Boolean` | `false` | Restore a marked object from the GLPI trash instead of creating a second one |
| `type_restore_trashed` | `Hash[String[1], Boolean]` | `{}` | Per-type override of `restore_trashed`, keyed by type name |
| `config_file` | `Stdlib::Absolutepath` | `<agent confdir>/glpi_transport.yaml` | Where the transport file is written; must be the path the agent's providers read |

`marker`, `type_markers`, `purge_max_fraction`, `purge_max_per_run` and `restore_trashed` are
explained in [Markers, adoption and purge](markers-and-purge.md); `unresolved` in
[Unresolved references](unresolved-references.md). A per-type override is keyed by the type
name, for example `type_markers => { 'glpi_cluster' => '[managed by puppet: clusters]' }` or
`type_restore_trashed => { 'glpi_custom_asset' => true }`.

`client_secret` and `password` must be `Sensitive`. When they come from Hiera, convert them with
`lookup_options`:

```yaml
lookup_options:
  glpi::client_secret:
    convert_to: Sensitive
  glpi::password:
    convert_to: Sensitive

glpi::client_secret: ENC[PKCS7,...]
glpi::password: ENC[PKCS7,...]
```

In a manifest, wrap them explicitly:

```puppet
class { 'glpi':
  base_url      => 'https://glpi.example.com/api.php',
  client_id     => 'puppet',
  client_secret => Sensitive(lookup('glpi::client_secret')),
  username      => 'puppet-api',
  password      => Sensitive(lookup('glpi::password')),
}
```

## Tokens and TLS

Only API v2 is used. The providers fetch an OAuth token from `<base_url>/token` with the
configured grant, one token per scope (`api`, and `graphql` only when a type needs it), and
refresh it once when GLPI answers HTTP 401. Neither the secrets nor the tokens are logged.

TLS verification is enabled by default. When GLPI uses a certificate from a private CA, point
`ssl_ca_file` at that CA's bundle. `ssl_verify => false` disables verification and allows
man-in-the-middle attacks on the API connection, which carries the service user's credentials;
avoid it outside a test setup.

## The transport file

The class writes the connection settings and the ownership settings (`marker`, `type_markers`,
`purge_max_fraction`, `purge_max_per_run`, `unresolved`, `restore_trashed`,
`type_restore_trashed`) to `config_file` (`root:root`, mode `0600`, content declared as
`Sensitive`), which the providers read at agent run time. Declare the class on every node that
declares `glpi_*` resources, in `site.pp`, a role or a profile.

- All `glpi_*` types automatically require the managed transport file when it is present in the
  catalog, so a single `puppet agent -t` applies the class and all `glpi_*` resources in the same
  pass. Without the file, a first run reads GLPI as empty and re-reads the real state before it
  writes anything.
- The providers always read `glpi_transport.yaml` from the agent's own confdir, so do not point
  `config_file` anywhere else.
- The default comes from the `glpi_confdir` fact, which reports the agent's own
  `Puppet[:confdir]`; only before that fact has been pluginsynced does it fall back to the
  compiling server's `$settings::confdir`, which differs when server and agent use different
  layouts. Set `config_file` explicitly in that case.
