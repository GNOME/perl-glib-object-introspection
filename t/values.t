#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 2;

SKIP: {
  skip 'SV → GValue not implemented', 1;
  is (Regress::test_int_value_arg (23), 23);
}
is (Regress::test_value_return (23), 23);
