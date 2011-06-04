#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 16;

my $data = 42;
my $result = 23;
my $callback  = sub { is shift, $data; return $result; };

is (test_callback_user_data ($callback, $data), $result);

is (test_callback_destroy_notify ($callback, $data), $result);
is (test_callback_destroy_notify ($callback, $data), $result);
is (test_callback_thaw_notifications (), 46);

test_callback_async ($callback, $data);
test_callback_async ($callback, $data);
is (test_callback_thaw_async (), $result);

my $obj = TestObj->new_callback ($callback, $data);
isa_ok ($obj, 'TestObj');
is (test_callback_thaw_notifications (), 23);
