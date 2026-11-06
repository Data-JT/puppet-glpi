<?php

/**
 * Managed by Puppet (glpi::api_access).
 *
 * Makes the GLPI OAuth client, the service user and its profile assignment
 * match a JSON config file, by booting the GLPI kernel locally.
 *
 * Usage: php glpi-api-bootstrap.php --config <file> [--check]
 *
 * Exit codes: 0 in sync (or changes applied), 2 changes needed (--check),
 * 1 error. Errors go to STDERR. No secret is ever printed.
 */

if (PHP_SAPI !== 'cli') {
    exit(1);
}

function bootstrap_fail(string $message): void
{
    fwrite(STDERR, "glpi-api-bootstrap: {$message}\n");
    exit(1);
}

function bootstrap_load_config(array $argv): array
{
    $config_path = null;
    $check = false;
    for ($i = 1; $i < count($argv); $i++) {
        if ($argv[$i] === '--check') {
            $check = true;
        } elseif ($argv[$i] === '--config' && isset($argv[$i + 1])) {
            $config_path = $argv[++$i];
        } else {
            bootstrap_fail('usage: glpi-api-bootstrap.php --config <file> [--check]');
        }
    }
    if ($config_path === null) {
        bootstrap_fail('usage: glpi-api-bootstrap.php --config <file> [--check]');
    }
    if (!is_readable($config_path)) {
        bootstrap_fail("config file {$config_path} is not readable");
    }
    $config = json_decode((string) file_get_contents($config_path), true);
    if (!is_array($config)) {
        bootstrap_fail("config file {$config_path} is not valid JSON");
    }
    $required = [
        'glpi_root' => null,
        'client'    => ['name', 'identifier', 'secret', 'grants', 'scopes'],
        'user'      => ['name', 'password'],
        'profile'   => ['name', 'entity_id', 'recursive'],
    ];
    foreach ($required as $section => $keys) {
        if (!array_key_exists($section, $config)) {
            bootstrap_fail("config file lacks '{$section}'");
        }
        foreach ($keys ?? [] as $key) {
            if (!is_array($config[$section]) || !array_key_exists($key, $config[$section])) {
                bootstrap_fail("config file lacks '{$section}.{$key}'");
            }
        }
    }
    return [$config, $check];
}

function bootstrap_session(): void
{
    global $DB;
    // Without the cron flag GLPI's right checks silently drop every field on add()/update().
    $_SESSION['glpicronuserrunning'] = 'cli';
    $_SESSION['glpi_currenttime'] = date('Y-m-d H:i:s');
    $_SESSION['glpiID'] = 0;
    $_SESSION['glpiactive_entity'] = 0;
    $entities = [];
    foreach ($DB->request(['SELECT' => ['id'], 'FROM' => 'glpi_entities']) as $row) {
        $entities[] = (int) $row['id'];
    }
    $_SESSION['glpiactiveentities'] = $entities;
    $_SESSION['glpiactiveentities_string'] = "'" . implode("', '", $entities) . "'";
}

/** Rows of $table matching $where, as arrays. */
function bootstrap_rows(string $table, array $where): array
{
    global $DB;
    $rows = [];
    foreach ($DB->request(['FROM' => $table, 'WHERE' => $where]) as $row) {
        $rows[] = $row;
    }
    return $rows;
}

function bootstrap_sorted(array $values): array
{
    $values = array_values(array_map('strval', $values));
    sort($values);
    return $values;
}

/** @return string[] differences of the OAuth client, as non-secret field names */
function bootstrap_client_diff(array $want, ?array $row): array
{
    if ($row === null) {
        return ['create'];
    }
    $diff = [];
    if ((string) $row['name'] !== $want['name']) {
        $diff[] = 'name';
    }
    $stored = (new GLPIKey())->decrypt((string) $row['secret']);
    if (!is_string($stored) || !hash_equals($stored, (string) $want['secret'])) {
        $diff[] = 'secret';
    }
    if (bootstrap_sorted(json_decode((string) $row['grants'], true) ?? []) !== bootstrap_sorted($want['grants'])) {
        $diff[] = 'grants';
    }
    if (bootstrap_sorted(json_decode((string) $row['scopes'], true) ?? []) !== bootstrap_sorted($want['scopes'])) {
        $diff[] = 'scopes';
    }
    if ((int) $row['is_active'] !== 1) {
        $diff[] = 'is_active';
    }
    return $diff;
}

function bootstrap_client(array $want, bool $check, array &$changes): void
{
    $rows = bootstrap_rows('glpi_oauthclients', ['identifier' => $want['identifier']]);
    if (count($rows) > 1) {
        bootstrap_fail("more than one OAuth client with identifier '{$want['identifier']}'");
    }
    $row = $rows[0] ?? null;
    $diff = bootstrap_client_diff($want, $row);
    if ($diff === []) {
        return;
    }
    $changes[] = $row === null
        ? "OAuth client '{$want['name']}': create"
        : "OAuth client '{$want['name']}': update " . implode(', ', $diff);
    if ($check) {
        return;
    }

    $client = new OAuthClient();
    if ($row === null) {
        // prepareInputForAdd() always generates a random identifier and secret;
        // the update below replaces both with the configured values.
        $id = $client->add([
            'name'      => $want['name'],
            'grants'    => $want['grants'],
            'scopes'    => $want['scopes'],
            'is_active' => 1,
        ]);
        if (!$id) {
            bootstrap_fail("could not create OAuth client '{$want['name']}'");
        }
        $redirect_uri = ['/api.php/oauth2/redirection'];
    } else {
        $id = (int) $row['id'];
        $redirect_uri = json_decode((string) $row['redirect_uri'], true) ?? [];
    }
    // prepareInputForUpdate() resets redirect_uri unless it is passed in.
    $ok = $client->update([
        'id'           => $id,
        'name'         => $want['name'],
        'identifier'   => $want['identifier'],
        'secret'       => $want['secret'],
        'grants'       => $want['grants'],
        'scopes'       => $want['scopes'],
        'is_active'    => 1,
        'redirect_uri' => $redirect_uri,
    ]);
    $after = bootstrap_rows('glpi_oauthclients', ['id' => $id])[0] ?? null;
    if (!$ok || $after === null || (string) $after['identifier'] !== $want['identifier']
        || bootstrap_client_diff($want, $after) !== []) {
        bootstrap_fail("could not update OAuth client '{$want['name']}'");
    }
}

/** @return string[] differences of the service user, as non-secret field names */
function bootstrap_user_diff(array $want, ?array $row): array
{
    if ($row === null) {
        return ['create'];
    }
    $diff = [];
    if ((int) $row['is_active'] !== 1) {
        $diff[] = 'is_active';
    }
    if ((int) $row['is_deleted'] !== 0) {
        $diff[] = 'is_deleted';
    }
    if (!is_string($row['password']) || !Auth::checkPassword($want['password'], $row['password'])) {
        $diff[] = 'password';
    }
    return $diff;
}

function bootstrap_user(array $want, array $profile, bool $check, array &$changes): ?int
{
    $rows = bootstrap_rows('glpi_users', ['name' => $want['name']]);
    if (count($rows) > 1) {
        bootstrap_fail("more than one user named '{$want['name']}'");
    }
    $row = $rows[0] ?? null;
    if ($row !== null && (int) $row['authtype'] !== Auth::DB_GLPI) {
        bootstrap_fail("user '{$want['name']}' exists but does not use local authentication; refusing to change it");
    }
    $diff = bootstrap_user_diff($want, $row);
    if ($diff === []) {
        return (int) $row['id'];
    }
    $changes[] = $row === null
        ? "user '{$want['name']}': create"
        : "user '{$want['name']}': update " . implode(', ', $diff);
    if ($check) {
        return $row === null ? null : (int) $row['id'];
    }

    $user = new User();
    $input = [
        'is_active'  => 1,
        'is_deleted' => 0,
        'password'   => $want['password'],
        'password2'  => $want['password'],
    ];
    if ($row === null) {
        $id = $user->add($input + [
            'name'          => $want['name'],
            'authtype'      => Auth::DB_GLPI,
            'auths_id'      => 0,
            // Assigned instead of GLPI's default profile.
            '_profiles_id'  => $profile['profiles_id'],
            '_entities_id'  => $profile['entities_id'],
            '_is_recursive' => $profile['is_recursive'],
        ]);
        if (!$id) {
            bootstrap_fail("could not create user '{$want['name']}'");
        }
    } else {
        $id = (int) $row['id'];
        $ok = $user->update($input + ['id' => $id]);
        if (!$ok) {
            bootstrap_fail("could not update user '{$want['name']}' (password policy?)");
        }
    }
    $after = bootstrap_rows('glpi_users', ['id' => $id])[0] ?? null;
    if (bootstrap_user_diff($want, $after) !== []) {
        // User::add() drops a password that violates the password policy without failing.
        bootstrap_fail("user '{$want['name']}' does not match after the change (password policy?)");
    }
    return (int) $id;
}

/** Resolves the configured profile assignment to IDs, or fails. */
function bootstrap_resolve_profile(array $want): array
{
    $profiles = bootstrap_rows('glpi_profiles', ['name' => $want['name']]);
    if (count($profiles) !== 1) {
        bootstrap_fail(count($profiles) . " profiles named '{$want['name']}', expected exactly one");
    }
    $entities_id = (int) $want['entity_id'];
    if (count(bootstrap_rows('glpi_entities', ['id' => $entities_id])) !== 1) {
        bootstrap_fail("entity {$entities_id} does not exist");
    }
    return [
        'name'         => $want['name'],
        'profiles_id'  => (int) $profiles[0]['id'],
        'entities_id'  => $entities_id,
        'is_recursive' => $want['recursive'] ? 1 : 0,
    ];
}

function bootstrap_profile(array $want, string $username, ?int $users_id, bool $check, array &$changes): void
{
    $profiles_id = $want['profiles_id'];
    $entities_id = $want['entities_id'];
    $recursive = $want['is_recursive'];
    $label = "profile '{$want['name']}' for '{$username}' in entity {$entities_id}";

    $rows = $users_id === null ? [] : bootstrap_rows('glpi_profiles_users', [
        'users_id'    => $users_id,
        'profiles_id' => $profiles_id,
        'entities_id' => $entities_id,
    ]);
    $keep = $rows[0] ?? null;
    $extra = array_slice($rows, 1);
    $todo = [];
    if ($keep === null) {
        $todo[] = 'create';
    } elseif ((int) $keep['is_recursive'] !== $recursive) {
        $todo[] = 'update is_recursive';
    }
    if ($extra !== []) {
        $todo[] = 'remove ' . count($extra) . ' duplicate(s)';
    }
    if ($todo === []) {
        return;
    }
    $changes[] = "{$label}: " . implode(', ', $todo);
    if ($check) {
        return;
    }

    $pu = new Profile_User();
    if ($keep === null) {
        $ok = $pu->add([
            'users_id'     => $users_id,
            'profiles_id'  => $profiles_id,
            'entities_id'  => $entities_id,
            'is_recursive' => $recursive,
            'is_dynamic'   => 0,
        ]);
    } elseif ((int) $keep['is_recursive'] !== $recursive) {
        $ok = $pu->update(['id' => (int) $keep['id'], 'is_recursive' => $recursive]);
    } else {
        $ok = true;
    }
    foreach ($extra as $dup) {
        $ok = $pu->delete(['id' => (int) $dup['id']], true) && $ok;
    }
    if (!$ok) {
        bootstrap_fail("could not set {$label}");
    }
}

/**
 * The API session starts in the user's default profile and entity. Without
 * them GLPI picks the default profile it attaches dynamically on first login.
 */
function bootstrap_user_defaults(array $profile, string $username, ?int $users_id, bool $check, array &$changes): void
{
    if ($users_id === null) {
        return; // --check on a user still to be created
    }
    $row = bootstrap_rows('glpi_users', ['id' => $users_id])[0] ?? null;
    $diff = [];
    if ((int) ($row['profiles_id'] ?? 0) !== $profile['profiles_id']) {
        $diff[] = 'default profile';
    }
    if ((int) ($row['entities_id'] ?? -1) !== $profile['entities_id']) {
        $diff[] = 'default entity';
    }
    if ($diff === []) {
        return;
    }
    $changes[] = "user '{$username}': update " . implode(', ', $diff);
    if ($check) {
        return;
    }
    $ok = (new User())->update([
        'id'          => $users_id,
        'profiles_id' => $profile['profiles_id'],
        'entities_id' => $profile['entities_id'],
    ]);
    $after = bootstrap_rows('glpi_users', ['id' => $users_id])[0] ?? null;
    if (!$ok || (int) ($after['profiles_id'] ?? 0) !== $profile['profiles_id']
        || (int) ($after['entities_id'] ?? -1) !== $profile['entities_id']) {
        bootstrap_fail("could not set the default profile and entity of user '{$username}'");
    }
}

[$config, $check] = bootstrap_load_config($argv);

// Boot at file scope and keep the name $kernel: GLPI's bootstrap files define
// globals, and isAPI() (called by User::update()) reads `global $kernel`.
$glpi_root = rtrim((string) $config['glpi_root'], '/');
if (!is_readable("{$glpi_root}/vendor/autoload.php")) {
    bootstrap_fail("{$glpi_root}/vendor/autoload.php not found; glpi_root must be the GLPI install directory");
}
chdir($glpi_root);
require "{$glpi_root}/vendor/autoload.php";
$kernel = new \Glpi\Kernel\Kernel('production');
$kernel->boot();
bootstrap_session();

$changes = [];
try {
    $profile = bootstrap_resolve_profile($config['profile']);
    bootstrap_client($config['client'], $check, $changes);
    $users_id = bootstrap_user($config['user'], $profile, $check, $changes);
    bootstrap_profile($profile, $config['user']['name'], $users_id, $check, $changes);
    bootstrap_user_defaults($profile, $config['user']['name'], $users_id, $check, $changes);
} catch (\Throwable $e) {
    // The exception class only: messages may quote input values.
    bootstrap_fail('unexpected ' . get_class($e) . ' at ' . basename($e->getFile()) . ':' . $e->getLine());
}

foreach ($changes as $line) {
    echo ($check ? 'would change ' : 'changed ') . $line, "\n";
}
exit($check && $changes !== [] ? 2 : 0);
