#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 4;

is (Regress::INT_CONSTANT, 4422);
delta_ok (Regress::DOUBLE_CONSTANT, 44.22);
is (Regress::STRING_CONSTANT, "Some String");
is (Regress::Mixed_Case_Constant, 4423);
