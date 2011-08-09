#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 36;

my $obj = TestObj->constructor;
isa_ok ($obj, 'TestObj');
isa_ok ($obj, 'Glib::Object');

$obj = TestObj->new ($obj);
isa_ok ($obj, 'TestObj');
isa_ok ($obj, 'Glib::Object');

$obj = TestObj->new_from_file ($0);
isa_ok ($obj, 'TestObj');
isa_ok ($obj, 'Glib::Object');

$obj->set_bare (TestObj->constructor);
is ($obj->instance_method, -1);
is (TestObj::static_method (23), 23);
$obj->forced_method;

my ($y, $z, $q) = $obj->torture_signature_0 (23, 'perl', 42);
is ($y, 23);
is ($z, 46);
is ($q, 46);

is (eval { $obj->torture_signature_1 (23, 'perl', 41); 1 }, undef);
like ($@, qr/odd/);

SKIP: {
  skip 'Skipping return values not implemented yet', 3;
  my ($b, $d, $sum) = $obj->skip_return_val (23, 42, 57, 13, 17);
  is ($b, 24);
  is ($d, 58);
  is ($sum, 13+170);
}

SKIP: {
  skip 'Skipping parameters not implemented yet', 10;
  my ($success, $b, $d, $sum);

  ($success, $b, $d, $sum) = $obj->skip_param (23, 57, 13, 17);
  ok ($success);
  is ($b, 24);
  is ($d, 58);
  is ($sum, 13+170);

  ($success, $d, $sum) = $obj->skip_out_param (23, 42, 57, 13, 17);
  ok ($success);
  is ($d, 58);
  is ($sum, 13+170);

  ($success, $b, $sum) = $obj->skip_inout_param (23, 42, 13, 17);
  ok ($success);
  is ($b, 24);
  is ($sum, 13+170);
}

is ($obj->do_matrix ('perl'), 42);

func_obj_null_in ($obj);
func_obj_null_in (undef);
is (TestObj::null_out (), undef);

# inheritance
my $sub = TestSubObj->new;
isa_ok ($sub, 'TestSubObj');
isa_ok ($sub, 'TestObj');
isa_ok ($sub, 'Glib::Object');
$sub->unset_bare;
is ($sub->instance_method, 0);

# unusual prefix
my $wi = TestWi8021x->new;
isa_ok ($wi, 'TestWi8021x');
isa_ok ($wi, 'Glib::Object');
$wi->set_testbool (1);
ok ($wi->get_testbool);
is (TestWi8021x::static_method (23), 46);
