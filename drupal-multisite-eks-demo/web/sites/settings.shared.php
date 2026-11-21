<?php

/**
 * @file
 * Runbook Phase 8: environment-driven settings shared by every site.
 *
 * Each site's settings.php sets $site_name and includes this file at the END,
 * so values injected by Kubernetes (ConfigMap + Secret) or Compose win over
 * older hard-coded ones. Per-site variables use the upper-cased site name as a
 * prefix: SITE_A_DB_NAME, SITE_A_DB_USER, SITE_A_DB_PASSWORD, SITE_A_HASH_SALT,
 * SITE_A_TRUSTED_HOSTS.
 */

if (empty($site_name) || !preg_match('/^[a-z0-9_]+$/', $site_name)) {
  throw new RuntimeException('settings.shared.php: set $site_name in the site\'s settings.php first.');
}
$env = getenv('APP_ENV') ?: 'local';
$p = strtoupper($site_name);

// A required variable that is missing should stop the site, not fall back silently.
$required = static function (string $name): string {
  $value = getenv($name);
  if ($value === FALSE || $value === '') {
    throw new RuntimeException("Environment variable $name is not set.");
  }
  return $value;
};

$databases['default']['default'] = [
  'driver' => 'mysql',
  'namespace' => 'Drupal\\mysql\\Driver\\Database\\mysql',
  'prefix' => '',
  'collation' => 'utf8mb4_general_ci',
  'host' => $required('DB_HOST'),
  'port' => getenv('DB_PORT') ?: '3306',
  'database' => getenv("{$p}_DB_NAME") ?: $site_name,
  // Per-site credentials (production) fall back to one shared user (local demo).
  'username' => getenv("{$p}_DB_USER") ?: $required('DB_USER'),
  'password' => getenv("{$p}_DB_PASSWORD") ?: $required('DB_PASSWORD'),
];

$settings['hash_salt'] = $required("{$p}_HASH_SALT");
$settings['config_sync_directory'] = "../config/{$site_name}/sync";
$settings['file_public_path'] = "sites/{$site_name}/files";
$settings['file_private_path'] = "/mnt/private/{$site_name}";
$settings['file_temp_path'] = '/tmp';
// Comma-separated regular expressions, e.g. '^site-a\.example\.org$'.
$settings['trusted_host_patterns'] = array_values(array_filter(array_map('trim', explode(',', $required("{$p}_TRUSTED_HOSTS")))));
$settings['update_free_access'] = FALSE;
$settings['skip_permissions_hardening'] = TRUE;

// Reverse proxy (ALB, optionally CloudFront). TRUSTED_PROXY_IPS lists exactly the
// addresses that connect to Drupal; see runbook "Verify the reverse-proxy configuration".
// Never trust REMOTE_ADDR dynamically or the whole VPC.
$settings['reverse_proxy_addresses'] = array_values(array_filter(array_map('trim', explode(',', getenv('TRUSTED_PROXY_IPS') ?: ''))));
$settings['reverse_proxy'] = (bool) $settings['reverse_proxy_addresses'];
$settings['reverse_proxy_trusted_headers'] = \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_FOR
  | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PROTO
  | \Symfony\Component\HttpFoundation\Request::HEADER_X_FORWARDED_PORT;

// Redis (ElastiCache). Only switch the cache backend once the redis module is
// installed AND enabled on the site (REDIS_ENABLED=1); pointing the cache at a
// service from a disabled module is a fatal error on every request.
if (getenv('REDIS_HOST') && getenv('REDIS_ENABLED') === '1' && file_exists(DRUPAL_ROOT . '/modules/contrib/redis')) {
  $settings['redis.connection']['interface'] = 'PhpRedis';
  $settings['redis.connection']['host'] = getenv('REDIS_HOST');
  $settings['cache_prefix'] = $site_name . '_';
  $settings['cache']['default'] = 'cache.backend.redis';
  $settings['container_yamls'][] = 'modules/contrib/redis/example.services.yml';
}

// Config split per environment (only takes effect once config_split is in use).
$config['config_split.config_split.local']['status'] = $env === 'local';
$config['config_split.config_split.prod']['status'] = $env === 'prod';

if (file_exists(__DIR__ . "/settings.{$env}.php")) {
  include __DIR__ . "/settings.{$env}.php";
}
