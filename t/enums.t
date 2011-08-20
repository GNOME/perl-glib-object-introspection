#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 3;

is (Regress::test_enum_param ('value1'), 'value1');
is (Regress::test_unsigned_enum_param ('value2'), 'value2');
is (Regress::global_get_flags_out (), ['flag1', 'flag3']);
