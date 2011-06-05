#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

use utf8;
use POSIX qw(FLT_MIN FLT_MAX DBL_MIN DBL_MAX);

plan tests => 34;

ok (test_boolean (1));
ok (!test_boolean (0));
is (test_int8 (-127), -127);
is (test_uint8 (255), 255);
is (test_int16 (-32767), -32767);
is (test_uint16 (65535), 65535);
is (test_int32 (-2147483647), -2147483647);
is (test_uint32 (4294967295), 4294967295);
is (test_int64 ('-9223372036854775807'), '-9223372036854775807');
is (test_uint64 ('18446744073709551615'), '18446744073709551615');
delta_ok (test_float (FLT_MIN), FLT_MIN);
delta_ok (test_float (FLT_MAX), FLT_MAX);
delta_ok (test_double (DBL_MIN), DBL_MIN);
delta_ok (test_double (DBL_MAX), DBL_MAX);

is (test_unichar ('ℵ'), 'ℵ');

my $time = time ();
is (test_timet ($time), $time);

is (test_gtype ('Glib::Object'), 'Glib::Object');
TODO: {
  local $TODO = 'Is that how we want to handle unregistered GTypes?';
  is (test_gtype ('GIRepository'),
      'Glib::Object::_Unregistered::GIRepository');
}
is (test_gtype ('Inexistant'), undef);

my $expected_const_string = 'const ♥ utf8';
my $expected_nonconst_string = 'nonconst ♥ utf8';
is (test_utf8_const_return (), $expected_const_string);
is (test_utf8_nonconst_return (), $expected_nonconst_string);
test_utf8_const_in (test_utf8_const_return ());
is (test_utf8_out (), $expected_nonconst_string);
is (test_utf8_inout (test_utf8_const_return ()), test_utf8_nonconst_return ());
test_utf8_null_in (undef);
is (test_utf8_null_out (), undef);

my $filenames = test_filename_return ();
is (scalar @$filenames, 2);
is ($filenames->[0], 'åäö');
is ($filenames->[1], '/etc/fstab');

is (test_int_out_utf8 ('Παν語'), 4);
my ($one, $two) = test_multi_double_args (my $pi = 3.1415);
delta_ok ($one, 2*$pi);
delta_ok ($two, 3*$pi);
($one, $two) = test_utf8_out_out ();
is ($one, 'first');
is ($two, 'second');
($one, $two) = test_utf8_out_nonconst_return ();
is ($one, 'first');
is ($two, 'second');
