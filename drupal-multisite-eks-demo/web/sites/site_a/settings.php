<?php

/**
 * @file
 * Settings for site_a.
 *
 * Site-specific overrides go ABOVE the include. Everything environment-specific
 * (database, hash salt, trusted hosts, proxies) comes from settings.shared.php,
 * which must stay the last line (runbook Phase 8).
 */

$site_name = 'site_a';
require DRUPAL_ROOT . '/sites/settings.shared.php';
