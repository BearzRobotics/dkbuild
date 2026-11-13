# FenrirOS: answers for Webmin's setup.sh (which reads this file), for the
# packaged tree in /usr/share/webmin. The login and password are still asked.
config_dir=/etc/webmin
var_dir=/var/webmin
perl=/usr/bin/perl
# the package already set the scripts' perl path
noperlpath=1
# dinit runs Webmin (/etc/dinit.d/webmin); no SysV/systemd boot script, no
# start at the end of setup
atboot=0
makeboot=0
nostart=1
# the package manager removes Webmin
nouninstall=1
