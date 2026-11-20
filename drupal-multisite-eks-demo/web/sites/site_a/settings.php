<?php
$databases['default']['default'] = [
  'database' => getenv('SITE_A_DB_NAME') ?: 'site_a',
  'username' => getenv('DB_USER'),
  'password' => getenv('DB_PASSWORD'),
  'prefix' => '',
  'host' => getenv('DB_HOST') ?: 'db',
  'port' => getenv('DB_PORT') ?: '3306',
  'namespace' => 'Drupal\\mysql\\Driver\\Database\\mysql',
  'driver' => 'mysql',
];
$settings['hash_salt'] = getenv('SITE_A_HASH_SALT') ?: 'local-demo-site-a-only';
$settings['trusted_host_patterns'] = [getenv('SITE_A_TRUSTED_HOSTS') ?: '^site-a\\.localhost$'];
$settings['config_sync_directory'] = '../config/site_a/sync';
$settings['file_public_path'] = 'sites/site_a/files';
$settings['file_private_path'] = '/tmp/site_a-private';
$settings['update_free_access'] = FALSE;
