#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 4;

{
  my $expected_struct = {long_ => 6, int8 => 7};
  my $struct = GI::SimpleStruct::returnv ();
  is_deeply ($struct, $expected_struct);
  GI::SimpleStruct::inv ($struct);
  GI::SimpleStruct::method ($struct);
  undef $struct;
  is_deeply (GI::SimpleStruct::returnv (), $expected_struct);
}

{
  my $expected_struct = {long_ => 42};
  my $struct = GI::PointerStruct::returnv ();
  is_deeply ($struct, $expected_struct);
  GI::PointerStruct::inv ($struct);
  undef $struct;
  is_deeply (GI::PointerStruct::returnv (), $expected_struct);
}
