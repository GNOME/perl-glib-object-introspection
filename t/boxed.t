#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;
use Scalar::Util qw/weaken/;

plan tests => 33;

{
  my $boxed = GI::BoxedStruct->new;
  isa_ok ($boxed, 'GI::BoxedStruct');
  weaken $boxed;
  is ($boxed, undef);
}

{
  my $boxed = GI::BoxedStruct::returnv ();
  isa_ok ($boxed, 'GI::BoxedStruct');
  $boxed->inv;
  weaken $boxed;
  is ($boxed, undef);
  # make sure we haven't destroyed the static object
  isa_ok (GI::BoxedStruct::returnv (), 'GI::BoxedStruct');
  isa_ok (GI::BoxedStruct::returnv ()->copy, 'GI::BoxedStruct');
}

{
  my $boxed = GI::BoxedStruct::out ();
  isa_ok ($boxed, 'GI::BoxedStruct');
  weaken $boxed;
  is ($boxed, undef);
  # make sure we haven't destroyed the static object
  isa_ok (GI::BoxedStruct::out (), 'GI::BoxedStruct');
  isa_ok (GI::BoxedStruct::out ()->copy, 'GI::BoxedStruct');
}

{
  my $boxed = GI::BoxedStruct::inout (GI::BoxedStruct::out ());
  isa_ok ($boxed, 'GI::BoxedStruct');
  weaken $boxed;
  is ($boxed, undef);
}

# --------------------------------------------------------------------------- #

{
  my $boxed = TestSimpleBoxedA::const_return ();
  isa_ok ($boxed, 'TestSimpleBoxedA');
  isa_ok ($boxed, 'Glib::Boxed');
  my $copy = $boxed->copy;
  ok ($boxed->equals ($copy));
  weaken $boxed;
  is ($boxed, undef);
  weaken $copy;
  is ($copy, undef);
}

{
  my $boxed = TestBoxed->new;
  isa_ok ($boxed, 'TestBoxed');
  isa_ok ($boxed, 'Glib::Boxed');
  my $copy = $boxed->copy;
  isa_ok ($boxed, 'TestBoxed');
  isa_ok ($boxed, 'Glib::Boxed');
  ok ($boxed->equals ($copy));
  weaken $boxed;
  is ($boxed, undef);
  weaken $copy;
  is ($copy, undef);

  $boxed = TestBoxed->new_alternative_constructor1 (23);
  isa_ok ($boxed, 'TestBoxed');
  isa_ok ($boxed, 'Glib::Boxed');
  weaken $boxed;
  is ($boxed, undef);

  $boxed = TestBoxed->new_alternative_constructor2 (23, 42);
  isa_ok ($boxed, 'TestBoxed');
  isa_ok ($boxed, 'Glib::Boxed');
  weaken $boxed;
  is ($boxed, undef);

  $boxed = TestBoxed->new_alternative_constructor3 ("perl");
  isa_ok ($boxed, 'TestBoxed');
  isa_ok ($boxed, 'Glib::Boxed');
  weaken $boxed;
  is ($boxed, undef);
}
