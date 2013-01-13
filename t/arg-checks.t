#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 5;

{
  is (Regress::test_int8 (-127), -127);
}

{
  is (eval { Regress::test_int8 () }, undef);
  like ($@, qr/too few/);
}

{
  local $SIG{__WARN__} = sub { like ($_[0], qr/too many/) };
  is (Regress::test_int8 (127, 'bla'), 127);
}
