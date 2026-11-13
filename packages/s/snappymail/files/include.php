<?php
// FenrirOS: SnappyMail's data (configuration, logs, caches, domains, the
// admin password it makes on first use) lives outside the served tree.
function __get_custom_data_full_path()
{
	return '/var/lib/snappymail';
}
