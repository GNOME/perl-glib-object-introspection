#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;
use utf8;

plan tests => 29;

ok (Regress::test_strv_in ([ '1', '2', '3' ]));

my $int_array = [ 1, 2, 3 ];
is (Regress::test_array_int_in ($int_array), 6);
is_deeply (Regress::test_array_int_out (), [0, 1, 2, 3, 4]);
is_deeply (Regress::test_array_int_inout ($int_array), [3, 4]);
is (Regress::test_array_gint8_in ($int_array), 6);
is (Regress::test_array_gint16_in ($int_array), 6);
is (Regress::test_array_gint32_in ($int_array), 6);
is (Regress::test_array_gint64_in ($int_array), 6);
is (Regress::test_array_gtype_in ([ 'Glib::Object', 'Glib::Int64' ]), "[GObject,gint64,]");
is (Regress::test_array_fixed_size_int_in ([ 1, 2, 3, 4, 5 ]), 15);
is_deeply (Regress::test_array_fixed_size_int_out (), [ 0, 1, 2, 3, 4 ]);
is_deeply (Regress::test_array_fixed_size_int_return (), [ 0, 1, 2, 3, 4 ]);
is_deeply (Regress::test_strv_out_container (), [ '1', '2', '3' ]);
is_deeply (Regress::test_strv_out (), [ 'thanks', 'for', 'all', 'the', 'fish' ]);
is_deeply (Regress::test_strv_out_c (), [ 'thanks', 'for', 'all', 'the', 'fish' ]);
is_deeply (Regress::test_strv_outarg (), [ '1', '2', '3' ]);

is_deeply (Regress::test_array_int_full_out (), [0, 1, 2, 3, 4]);
is_deeply (Regress::test_array_int_none_out (), [1, 2, 3, 4, 5]);
Regress::test_array_int_null_in (undef);
is (Regress::test_array_int_null_out, undef);

my $test_list = [1, 2, 3];
is_deeply (Regress::test_glist_nothing_return (), $test_list);
is_deeply (Regress::test_glist_nothing_return2 (), $test_list);
is_deeply (Regress::test_glist_container_return (), $test_list);
is_deeply (Regress::test_glist_everything_return (), $test_list);
Regress::test_glist_nothing_in ($test_list);
Regress::test_glist_nothing_in2 ($test_list);
Regress::test_glist_null_in (undef);
is (Regress::test_glist_null_out (), undef);

is_deeply (Regress::test_gslist_nothing_return (), $test_list);
is_deeply (Regress::test_gslist_nothing_return2 (), $test_list);
is_deeply (Regress::test_gslist_container_return (), $test_list);
is_deeply (Regress::test_gslist_everything_return (), $test_list);
Regress::test_gslist_nothing_in ($test_list);
Regress::test_gslist_nothing_in2 ($test_list);
Regress::test_gslist_null_in (undef);
is (Regress::test_gslist_null_out (), undef);
