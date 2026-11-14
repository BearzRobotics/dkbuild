# FenrirOS: pgAdmin 4 distribution settings (this file replaces the stub that
# upstream's wheel ships; its two lines are kept at the end).
SERVER_MODE = True
DATA_DIR = '/var/lib/pgadmin4'
LOG_FILE = '/var/log/pgadmin4/pgadmin4.log'
SQLITE_PATH = '/var/lib/pgadmin4/pgadmin4.db'
SESSION_DB_PATH = '/var/lib/pgadmin4/sessions'
STORAGE_DIR = '/var/lib/pgadmin4/storage'
AZURE_CREDENTIAL_CACHE_DIR = '/var/lib/pgadmin4/azurecredentialcache'
DEFAULT_SERVER = '127.0.0.1'
DEFAULT_SERVER_PORT = 5050
# updates come from the package
UPGRADE_CHECK_ENABLED = False
HELP_PATH = '../../docs/en_US/_build/html/'
MINIFY_HTML = False
