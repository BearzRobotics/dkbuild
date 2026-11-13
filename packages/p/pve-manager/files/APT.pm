package PVE::API2::APT;

# FenrirOS replacement for pve-manager's PVE::API2::APT: the node's "Updates"
# API on apk instead of APT (Debian's version needs AptPkg, dpkg and apt-get).
# Same paths, parameters and result fields, so the web UI, pveversion,
# pveupdate and pveupgrade work unchanged:
#   GET  update      packages with an upgrade (apk list --upgradable)
#   POST update      apk update as a task (with an http proxy from datacenter.cfg)
#   GET  versions    installed versions of the Proxmox VE packages (apk)
#   GET  changelog   not available from apk; a short message
#   GET/PUT/POST repositories   apk repositories are not managed here; GET
#                    returns /etc/apk/repositories as read-only information
# Written for FenrirOS.

use strict;
use warnings;

use POSIX;
use File::stat ();
use JSON;

use PVE::Tools qw(extract_param);
use PVE::Cluster;
use PVE::SafeSyslog;
use PVE::INotify;
use PVE::Exception;
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Notify;
use PVE::pvecfg;

use base qw(PVE::RESTHandler);

my $pve_pkgstatus_fn = "/var/lib/pve-manager/pkgupdates";

my $apt_package_return_props = {
    Arch => { type => 'string', description => 'Package architecture.' },
    Description => { type => 'string', description => 'Package description.' },
    NotifyStatus => {
        type => 'string',
        description => 'Version for which PVE has already sent an update notification for.',
        optional => 1,
    },
    OldVersion => { type => 'string', description => 'Old version currently installed.', optional => 1 },
    Origin => { type => 'string', description => "Package origin, e.g., 'FenrirOS'." },
    Package => { type => 'string', description => 'Package name.' },
    Priority => { type => 'string', description => 'Package priority.' },
    Section => { type => 'string', description => 'Package section.' },
    Title => { type => 'string', description => 'Package title.' },
    Version => { type => 'string', description => 'New version to be updated to.' },
};

# apk list prints "name-version-rN arch {origin} (license) [state]"
my sub parse_apk_list_line {
    my ($line) = @_;
    my ($nv, $arch, $origin, $rest) = $line =~ m/^(\S+)\s+(\S+)\s+\{([^}]*)\}\s*(.*)$/
        or return undef;
    my ($name, $ver) = $nv =~ m/^(.+?)-(\d[^-]*-r\d+)$/ or return undef;
    my $old;
    $old = $1 if $rest =~ m/\[upgradable from: \S+?-(\d[^-]*-r\d+)\]/;
    return { name => $name, version => $ver, arch => $arch, origin => $origin, old => $old };
}

my sub apk_list {
    my (@args) = @_;
    my $list = [];
    PVE::Tools::run_command(
        ['apk', 'list', @args],
        outfunc => sub {
            my $p = parse_apk_list_line(shift);
            push @$list, $p if $p;
        },
        errfunc => sub { },
        noerr => 1,
    );
    return $list;
}

my $assemble = sub {
    my ($p) = @_;
    return {
        Package => $p->{name},
        Title => $p->{name},
        Description => $p->{name},
        Version => $p->{version},
        (defined($p->{old}) ? (OldVersion => $p->{old}) : ()),
        Arch => $p->{arch},
        Origin => $p->{origin} || 'FenrirOS',
        Priority => 'optional',
        Section => 'admin',
    };
};

my $update_pve_pkgstatus = sub {
    syslog('info', "update new package list: $pve_pkgstatus_fn");

    my $oldpkglist = {};
    if (my $raw = eval { PVE::Tools::file_get_contents($pve_pkgstatus_fn) }) {
        my $old = eval { decode_json($raw) } // [];
        $oldpkglist->{ $_->{Package} } = $_ for @$old;
    }

    my $pkglist = [];
    for my $p (apk_list('--upgradable')->@*) {
        my $info = $assemble->($p);
        if (my $o = $oldpkglist->{ $info->{Package} }) {
            $info->{NotifyStatus} = $o->{NotifyStatus}
                if $o->{NotifyStatus} && $o->{Version} eq $info->{Version};
        }
        push @$pkglist, $info;
    }

    PVE::Tools::file_set_contents($pve_pkgstatus_fn, encode_json($pkglist));
    return $pkglist;
};

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Directory index for package updates (apk on FenrirOS).",
    permissions => { user => 'all' },
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => {
        type => "array",
        items => { type => "object", properties => { id => { type => 'string' } } },
        links => [{ rel => 'child', href => "{id}" }],
    },
    code => sub {
        return [{ id => 'changelog' }, { id => 'repositories' }, { id => 'update' }, { id => 'versions' }];
    },
});

__PACKAGE__->register_method({
    name => 'list_updates',
    path => 'update',
    method => 'GET',
    description => "List available updates.",
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => {
        type => "array",
        items => { type => "object", properties => $apt_package_return_props },
    },
    code => sub {
        my ($param) = @_;
        my $st1 = File::stat::stat($pve_pkgstatus_fn);
        my $st2 = File::stat::stat("/lib/apk/db/installed");
        if ($st1 && $st2 && $st2->mtime <= $st1->mtime) {
            my $data = eval { decode_json(PVE::Tools::file_get_contents($pve_pkgstatus_fn)) };
            return $data if $data;
        }
        return $update_pve_pkgstatus->();
    },
});

__PACKAGE__->register_method({
    name => 'update_database',
    path => 'update',
    method => 'POST',
    description => "Resynchronize the package index (apk update).",
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            notify => {
                type => 'boolean',
                description => "Send notification about new packages.",
                optional => 1,
                default => 0,
            },
            quiet => {
                type => 'boolean',
                description => "Only produces output suitable for logging, omitting progress indicators.",
                optional => 1,
                default => 0,
            },
        },
    },
    returns => { type => 'string' },
    code => sub {
        my ($param) = @_;

        my $rpcenv = PVE::RPCEnvironment::get();
        my $dcconf = PVE::Cluster::cfs_read_file('datacenter.cfg');
        my $authuser = $rpcenv->get_user();

        my $realcmd = sub {
            my $upid = shift;

            local $ENV{http_proxy} = $dcconf->{http_proxy} if $dcconf->{http_proxy};
            local $ENV{https_proxy} = $dcconf->{http_proxy} if $dcconf->{http_proxy};

            print "starting apk update\n" if !$param->{quiet};
            my $cmd = ['apk', 'update'];
            if ($param->{quiet}) {
                PVE::Tools::run_command($cmd, outfunc => sub { }, errfunc => sub { });
            } else {
                PVE::Tools::run_command($cmd);
            }

            my $pkglist = $update_pve_pkgstatus->();

            if ($param->{notify} && scalar(@$pkglist)) {
                my $updates_table = {
                    schema => {
                        columns => [
                            { label => "Package Name", id => "package-name" },
                            { label => "Installed Version", id => "installed-version" },
                            { label => "Available Version", id => "available-version" },
                        ],
                    },
                    data => [],
                };
                my $count = 0;
                for my $p (sort { $a->{Package} cmp $b->{Package} } @$pkglist) {
                    next if $p->{NotifyStatus} && $p->{NotifyStatus} eq $p->{Version};
                    $count++;
                    push $updates_table->{data}->@*, {
                        "package-name" => $p->{Package},
                        "installed-version" => $p->{OldVersion},
                        "available-version" => $p->{Version},
                    };
                }
                return if !$count;

                my $template_data = PVE::Notify::common_template_data();
                $template_data->{"available-updates"} = $updates_table;
                PVE::Notify::info("package-updates", $template_data,
                    { type => 'package-updates', hostname => PVE::INotify::nodename() });

                $_->{NotifyStatus} = $_->{Version} for @$pkglist;
                PVE::Tools::file_set_contents($pve_pkgstatus_fn, encode_json($pkglist));
            }
            return;
        };

        return $rpcenv->fork_worker('aptupdate', undef, $authuser, $realcmd);
    },
});

__PACKAGE__->register_method({
    name => 'changelog',
    path => 'changelog',
    method => 'GET',
    description => "Get package changelogs (not available from apk).",
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            name => { description => "Package name.", type => 'string' },
            version => { description => "Package version.", type => 'string', optional => 1 },
        },
    },
    returns => { type => "string" },
    code => sub {
        my ($param) = @_;
        return "apk packages carry no changelog; see the FenrirOS repository for $param->{name}.\n";
    },
});

__PACKAGE__->register_method({
    name => 'repositories',
    path => 'repositories',
    method => 'GET',
    proxyto => 'node',
    description => "Get the package repositories (read-only: /etc/apk/repositories).",
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => "object" },
    code => sub {
        my ($param) = @_;
        my $fn = '/etc/apk/repositories';
        my $raw = eval { PVE::Tools::file_get_contents($fn) } // '';
        my $repos = [];
        for my $line (split(/\n/, $raw)) {
            my $enabled = $line !~ m/^\s*#/ ? 1 : 0;
            (my $uri = $line) =~ s/^\s*#\s*//;
            next if $uri !~ m/\S/;
            push @$repos, {
                Types => ['apk'],
                URIs => [$uri],
                Suites => [''],
                Components => [],
                Options => [],
                Comment => '',
                FileType => 'list',
                Enabled => $enabled,
            };
        }
        return {
            files => [{ path => $fn, 'file-type' => 'list', repositories => $repos, digest => [] }],
            errors => [],
            digest => '',
            infos => [],
            'standard-repos' => [],
        };
    },
});

__PACKAGE__->register_method({
    name => 'add_repository',
    path => 'repositories',
    method => 'PUT',
    description => "Add a standard repository (not supported with apk).",
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            handle => { type => 'string' },
            digest => { type => 'string', optional => 1 },
        },
    },
    returns => { type => 'null' },
    code => sub { die "apk repositories are configured in /etc/apk/repositories\n" },
});

__PACKAGE__->register_method({
    name => 'change_repository',
    path => 'repositories',
    method => 'POST',
    description => "Change a repository (not supported with apk).",
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    protected => 1,
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            path => { type => 'string' },
            index => { type => 'integer' },
            enabled => { type => 'boolean', optional => 1 },
            digest => { type => 'string', optional => 1 },
        },
    },
    returns => { type => 'null' },
    code => sub { die "apk repositories are configured in /etc/apk/repositories\n" },
});

# the FenrirOS packages of Proxmox VE, most important first
my @pve_packages = qw(
    pve-manager pve-common pve-cluster pve-access-control pve-storage pve-guest-common
    qemu-server pve-container pve-firewall pve-network pve-ha-manager pve-http-server
    pve-apiclient pve-rs pve-rs-common proxmox-acme proxmox-widget-toolkit pve-docs
    proxmox-i18n extjs novnc-pve pve-xtermjs proxmox-termproxy vncterm spiceterm
    pve-lxc-syscalld pve-qemu pve-edk2-firmware corosync libqb kronosnet lxc lxcfs zfs
    lvm2 openvswitch dnsmasq swtpm smartmontools linux
);

__PACKAGE__->register_method({
    name => 'versions',
    path => 'versions',
    method => 'GET',
    proxyto => 'node',
    description => "Get package information for important Proxmox packages.",
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => {
        type => "array",
        items => {
            type => "object",
            properties => {
                $apt_package_return_props->%*,
                CurrentState => { type => 'string' },
                RunningKernel => { type => 'string', optional => 1 },
                ManagerVersion => { type => 'string', optional => 1 },
            },
        },
    },
    code => sub {
        my ($param) = @_;

        my $installed = { map { $_->{name} => $_ } apk_list('--installed')->@* };
        my (undef, undef, $kernel_release) = POSIX::uname();

        my $pkglist = [];
        for my $name (@pve_packages) {
            my $p = $installed->{$name} or next;
            my $res = $assemble->($p);
            $res->{OldVersion} = $p->{version};
            $res->{CurrentState} = 'Installed';
            $res->{ManagerVersion} = PVE::pvecfg::version_text() if $name eq 'pve-manager';
            $res->{RunningKernel} = $kernel_release if $name eq 'linux';
            push @$pkglist, $res;
        }
        return $pkglist;
    },
});

1;
