<?php

/**
 * @file
 * Catch-all for hostnames that sites.php does not map.
 *
 * Without this file Drupal would offer its installer on any unknown
 * hostname. Refuse the request instead.
 */
if (PHP_SAPI !== 'cli') {
  http_response_code(404);
  header('Content-Type: text/plain; charset=utf-8');
  exit("Unknown site.\n");
}
throw new RuntimeException('No site matches this URI. Pass --uri for one of the hosts in web/sites/sites.php.');
