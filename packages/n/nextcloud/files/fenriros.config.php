<?php
// FenrirOS: settings for the packaged Nextcloud, merged with config.php.
// The installer's own settings (database, secrets, trusted domains) go to
// config.php beside this file.
$CONFIG = [
    // the data directory the installer offers
    'datadirectory' => '/var/lib/nextcloud/data',
    // the packaged apps (read-only) and the app store's (writable)
    'apps_paths' => [
        ['path' => '/usr/share/nextcloud/apps', 'url' => '/apps', 'writable' => false],
        ['path' => '/usr/share/nextcloud/apps-extra', 'url' => '/apps-extra', 'writable' => true],
    ],
    // the package is what updates Nextcloud
    'upgrade.disable-web' => true,
    'updatechecker' => false,
];
