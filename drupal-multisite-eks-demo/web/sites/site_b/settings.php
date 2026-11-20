<?php
$databases['default']['default'] = [
  'database' => getenv('SITE_B_DB_NAME') ?: 'site_b',
  'username' => getenv('DB_USER'),
  'password' => getenv('DB_PASSWORD'),
  'prefix' => '',
  'host' => getenv('DB_HOST') ?: 'db',
  'port' => getenv('DB_PORT') ?: '3306',
  'namespace' => 'Drupal\\mysql\\Driver\\Database\\mysql',
  'driver' => 'mysql',
];
$settings['hash_salt'] = getenv('SITE_B_HASH_SALT') ?: 'local-demo-site-b-only';
$settings['trusted_host_patterns'] = [getenv('SITE_B_TRUSTED_HOSTS') ?: '^site-b\\.localhost$'];
$settings['file_public_path'] = 'sites/site_b/files';
$settings['file_private_path'] = '/tmp/site_b-private';
$settings['update_free_access'] = FALSE;
