#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;
use utf8;

plan tests => 20;

my $str_array = [ '1', '2', '3' ];
ok (test_strv_in ($str_array));

my $int_array = [ 1, 2, 3 ];
is (test_array_int_in (3, $int_array), 6);
is (test_array_gint8_in (3, $int_array), 6);
is (test_array_gint16_in (3, $int_array), 6);
is (test_array_gint32_in (3, $int_array), 6);
is (test_array_gint64_in (3, $int_array), 6);
is (test_array_gtype_in (2, [ 'Glib::Object', 'Glib::Int64' ]), "[GObject,gint64,]");
is (test_array_fixed_size_int_in ([ 1, 2, 3, 4, 5 ]), 15);
is_deeply (test_array_fixed_size_int_out (), [ 0, 1, 2, 3, 4 ]);
is_deeply (test_array_fixed_size_int_return (), [ 0, 1, 2, 3, 4 ]);

# TODO:
#void regress_test_array_int_out (int *n_ints, int **ints);
#void regress_test_array_int_inout (int *n_ints, int **ints);
#char **regress_test_strv_out_container (void);
#char **regress_test_strv_out (void);
#const char * const * regress_test_strv_out_c (void);
#void   regress_test_strv_outarg (char ***retp);
#void regress_test_array_fixed_size_int_out (int **ints);
#int *regress_test_array_fixed_size_int_return (void);

# TODO:
#int *regress_test_array_int_full_out(int *len);
#int *regress_test_array_int_none_out(int *len);
#void regress_test_array_int_null_in (int *arr, int len);
#void regress_test_array_int_null_out (int **arr, int *len);

my $test_list = [1, 2, 3];
is_deeply (test_glist_nothing_return (), $test_list);
is_deeply (test_glist_nothing_return2 (), $test_list);
is_deeply (test_glist_container_return (), $test_list);
is_deeply (test_glist_everything_return (), $test_list);
test_glist_nothing_in ($test_list);
test_glist_nothing_in2 ($test_list);
test_glist_null_in (undef);
is (test_glist_null_out (), undef);

is_deeply (test_gslist_nothing_return (), $test_list);
is_deeply (test_gslist_nothing_return2 (), $test_list);
is_deeply (test_gslist_container_return (), $test_list);
is_deeply (test_gslist_everything_return (), $test_list);
test_gslist_nothing_in ($test_list);
test_gslist_nothing_in2 ($test_list);
test_gslist_null_in (undef);
is (test_gslist_null_out (), undef);
