#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 4;

is (INT_CONSTANT, 4422);
delta_ok (DOUBLE_CONSTANT, 44.22);
is (STRING_CONSTANT, "Some String");
is (Mixed_Case_Constant, 4423);
