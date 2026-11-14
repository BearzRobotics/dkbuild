#!/usr/bin/perl
# Generates what tlmgr would write after installing the packages in ROOT:
# fmtutil.cnf, updmap.cfg, language.dat, language.def and language.dat.lua, from the
# `execute` lines of the installed packages' tlpobj files, with TeX Live's own
# TeXLive::TLUtils (the Perl modules of the texlive.infra container).
# usage: gen-config.pl ROOT   (ROOT contains tlpkg/ and texmf-dist/; it is /usr/share on the target)
use strict;
use warnings;
my $root;
BEGIN { $root = shift @ARGV; die "usage: gen-config.pl ROOT\n" unless defined $root && -d "$root/tlpkg"; unshift @INC, "$root/tlpkg"; }
use TeXLive::TLPDB;
use TeXLive::TLUtils;

# tlpkg/texlive.tlpdb is every installed package's tlpobj, one after the other
my $db = "$root/tlpkg/texlive.tlpdb";
opendir(my $dh, "$root/tlpkg/tlpobj") or die "no tlpobj directory: $!";
my @objs = sort grep { /\.tlpobj$/ } readdir($dh);
closedir($dh);
open(my $out, '>', $db) or die "$db: $!";
for my $o (@objs) {
    open(my $in, '<', "$root/tlpkg/tlpobj/$o") or die "$o: $!";
    local $/; my $t = <$in>; close($in);
    $t =~ s/\s+\z//;
    print $out "$t\n\n";
}
close($out);

my $tlpdb = TeXLive::TLPDB->new(root => $root) or die "cannot read $db";
my $web2c = "$root/texmf-dist/web2c";
my $cfg   = "$root/texmf-dist/tex/generic/config";
mkdir $web2c; 
TeXLive::TLUtils::create_fmtutil($tlpdb, "$web2c/fmtutil.cnf");
TeXLive::TLUtils::create_updmap($tlpdb, "$web2c/updmap.cfg");
TeXLive::TLUtils::create_language_dat($tlpdb, "$cfg/language.dat");
TeXLive::TLUtils::create_language_def($tlpdb, "$cfg/language.def");
TeXLive::TLUtils::create_language_lua($tlpdb, "$cfg/language.dat.lua");
for my $f ("$web2c/fmtutil.cnf", "$web2c/updmap.cfg", "$cfg/language.dat", "$cfg/language.def", "$cfg/language.dat.lua") {
    die "$f was not written" unless -s $f;
}
