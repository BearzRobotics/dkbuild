<?php
// FenrirOS: configuration in /etc/glpi, data in /var/lib/glpi, logs in
// /var/log/glpi; local overrides in /etc/glpi/local_define.php.
define('GLPI_CONFIG_DIR', '/etc/glpi');
define('GLPI_VAR_DIR', '/var/lib/glpi');
define('GLPI_LOG_DIR', '/var/log/glpi');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
