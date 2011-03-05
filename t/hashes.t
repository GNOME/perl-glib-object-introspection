#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;
use utf8;

plan tests => 8;

is(test_ghash_null_return(), undef);
is_deeply(test_ghash_nothing_return(), { foo => 'bar', baz => 'bat', qux => 'quux' });
is_deeply(test_ghash_nothing_return2(), { foo => 'bar', baz => 'bat', qux => 'quux' });
is_deeply(test_ghash_container_return(), { foo => 'bar', baz => 'bat', qux => 'quux' });
is_deeply(test_ghash_everything_return(), { foo => 'bar', baz => 'bat', qux => 'quux' });
test_ghash_null_in(undef);
is(test_ghash_null_out(), undef);
test_ghash_nothing_in({ foo => 'bar', baz => 'bat', qux => 'quux' });
test_ghash_nothing_in2({ foo => 'bar', baz => 'bat', qux => 'quux' });
is_deeply(test_ghash_nested_everything_return(), { wibble => { foo => 'bar', baz => 'bat', qux => 'quux', }, });
is_deeply(test_ghash_nested_everything_return2(), { wibble => { foo => 'bar', baz => 'bat', qux => 'quux', }, });
