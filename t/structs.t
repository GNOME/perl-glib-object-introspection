#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 6;

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

{
  my $expected_struct = {
    some_int => 23, some_int8 => 42, some_double => 11, some_enum => 'value1'};
  is_deeply (TestStructA::clone ($expected_struct), $expected_struct);
}

{
  my $expected_struct = {
    some_int8 => 32,
    nested_a => {
      some_int => 23, some_int8 => 42,
      some_double => 11, some_enum => 'value1'}};
  is_deeply (TestStructB::clone ($expected_struct), $expected_struct);
}
