#!/usr/bin/env perl
use Test::More;
#use Test::More tests => 3;

BEGIN : {
    use RNAseqDB::DB;
}

ok defined(my $rdb = RNAseqDB::DB->connect()), "Constructor";
isa_ok($rdb, "RNAseqDB::DB", "RNAseqDB::DB constructor");

my @methods = qw(
  connect
  add_sra
  add_species
);
can_ok($rdb, @methods);

done_testing();

