#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 4;

{
  package Foo;
  use Glib::Object::Subclass
    'Glib::Object',
      interfaces => [ 'GI::Interface' ];
}

{
  my $foo = Foo->new;
  local $@;
  eval { $foo->test_int8_in (23) };
  like ($@, qr/TEST_INT8_IN/);
}

{
  package Bar;
  use Glib::Object::Subclass
    'Glib::Object',
      interfaces => [ 'GI::Interface' ];
  sub TEST_INT8_IN {
    my ($self, $int8) = @_;
    Test::More::isa_ok ($self, 'Bar');
    Test::More::isa_ok ($self, 'GI::Interface');
  }
}

{
  my $bar = Bar->new;
  $bar->test_int8_in (23);
  ok (1);
}
