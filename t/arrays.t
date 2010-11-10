#!/usr/bin/env perl

BEGIN { require './t/inc/setup.pl' };

use strict;
use warnings;

plan tests => 10;

# TODO:
#gboolean regress_test_strv_in (char **arr);
#int regress_test_array_int_in (int n_ints, int *ints);
#void regress_test_array_int_out (int *n_ints, int **ints);
#void regress_test_array_int_inout (int *n_ints, int **ints);
#int regress_test_array_gint8_in (int n_ints, gint8 *ints);
#int regress_test_array_gint16_in (int n_ints, gint16 *ints);
#gint32 regress_test_array_gint32_in (int n_ints, gint32 *ints);
#gint64 regress_test_array_gint64_in (int n_ints, gint64 *ints);
#char *regress_test_array_gtype_in (int n_types, GType *types);
#char **regress_test_strv_out_container (void);
#char **regress_test_strv_out (void);
#const char * const * regress_test_strv_out_c (void);
#void   regress_test_strv_outarg (char ***retp);
#int regress_test_array_fixed_size_int_in (int *ints);
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
