package PVE::RADOS;

# FenrirOS stand-in for Proxmox's librados2-perl (PVE::RADOS, an XS binding
# of Ceph's librados). Ceph is not packaged for FenrirOS yet; this module lets
# pve-storage's RBD/CephFS plugins and pve-manager's Ceph API load, and makes
# every Ceph operation fail with a clear message. Remove it when a real
# librados2-perl is packaged.

use strict;
use warnings;

sub new {
    die "Ceph (librados) is not available on FenrirOS\n";
}

our $AUTOLOAD;
sub AUTOLOAD {
    my $name = $AUTOLOAD;
    $name =~ s/.*:://;
    return if $name eq 'DESTROY';
    die "Ceph (librados) is not available on FenrirOS\n";
}

1;
