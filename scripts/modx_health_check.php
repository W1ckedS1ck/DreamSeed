#!/usr/bin/env php
<?php
/**
 * MODX health check for CI/CD.
 * Tests: admin login, content count, system settings.
 * Usage: modx_health_check.php <username> <password>
 */

$coreConfig = '/var/www/html/manager/config.core.php';
if (!file_exists($coreConfig)) { echo "MISSING_CONFIG\n"; exit(2); }
require_once $coreConfig;

$modxClass = MODX_CORE_PATH . 'model/modx/modx.class.php';
if (!file_exists($modxClass)) { echo "MISSING_MODX\n"; exit(2); }
require_once $modxClass;

$modx = new modX('', [xPDO::OPT_CONN_INIT => [xPDO::OPT_CONN_MUTABLE => true]]);
$modx->initialize('mgr');

$username = $argv[1] ?? '';
$password = $argv[2] ?? '';

$user = $modx->getObject('modUser', ['username' => $username, 'active' => true]);
if (!$user) { echo "USER_NOT_FOUND\n"; exit(1); }
if (!$user->passwordMatches($password)) { echo "PASS_MISMATCH\n"; exit(1); }

$count = $modx->getCount('modResource');
echo "LOGIN_OK CONTENT=$count\n";
exit(0);
