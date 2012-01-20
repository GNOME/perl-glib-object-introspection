# Copyright (C) 2010-2012 Torsten Schoenfeld <kaffeetisch@gmx.de>
#
# This library is free software; you can redistribute it and/or modify it under
# the terms of the GNU Library General Public License as published by the Free
# Software Foundation; either version 2.1 of the License, or (at your option)
# any later version.
#
# This library is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU Library General Public License for
# more details.
#
# You should have received a copy of the GNU Library General Public License
# along with this library; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

BEGIN { require 5.008; }

use strict;
use warnings;
use ExtUtils::MakeMaker;
use File::Spec;
use Cwd;

my %PREREQ_PM = (
  'ExtUtils::Depends'   => 0.300,
  'ExtUtils::PkgConfig' => 1.000,
  'Glib'                => 1.240,
);

my %BUILD_REQ = (
  'gobject-introspection-1.0' => '0.10.0',
);

my $dep_success = eval <<__EOE__;
  use ExtUtils::Depends $PREREQ_PM{'ExtUtils::Depends'};
  use ExtUtils::PkgConfig $PREREQ_PM{'ExtUtils::PkgConfig'};
  use Glib $PREREQ_PM{'Glib'};
  use Glib::MakeHelper;
  1;
__EOE__
if (!$dep_success) {
  warn $@;
  exit 0;
}

my %cfg;
my $cfg_success = eval {
  %cfg = ExtUtils::PkgConfig->find (
    "gobject-introspection-1.0 >= $BUILD_REQ{'gobject-introspection-1.0'}");
  1;
};
if (!$cfg_success) {
  warn $@;
  exit 0;
}

my @xs_files = qw(GObjectIntrospection.xs);

my %pm_files = (
  'lib/Glib/Object/Introspection.pm' => '$(INST_LIBDIR)/Introspection.pm',
);
my %pod_files = (
   'lib/Glib/Object/Introspection.pm'
     => '$(INST_MAN3DIR)/Glib::Object::Introspection.$(MAN3EXT)',
);

mkdir 'build', 0777;

compile_test_libraries();

ExtUtils::PkgConfig->write_version_macros (
  "build/gi-version.h",
  "gobject-introspection-1.0" => "GI",
);

my $deps = ExtUtils::Depends->new ('Glib::Object::Introspection' => 'Glib');
$deps->set_inc ($cfg{cflags});
$deps->set_libs ($cfg{libs});
$deps->add_pm (%pm_files);
$deps->add_xs (@xs_files);
$deps->save_config ('build/IFiles.pm');

WriteMakefile(
  NAME		=> 'Glib::Object::Introspection',
  VERSION_FROM	=> 'lib/Glib/Object/Introspection.pm',
  ABSTRACT_FROM	=> 'lib/Glib/Object/Introspection.pm',
  PREREQ_PM	=> \%PREREQ_PM,
  XSPROTOARG	=> '-noprototypes',
  MAN3PODS	=> \%pod_files,

  META_MERGE => {
    configure_requires => \%PREREQ_PM,
    no_index => {
      file => \@xs_files,
      package => [ 'MY', 'Glib::Object::Introspection::_FuncWrapper' ],
    },
  },

  $deps->get_makefile_vars,
);

sub compile_test_libraries {
  chdir 'build';
  my $build_dir = cwd();

  local $| = 1;
  print 'Trying to build test libraries... ';

  my $success = eval {
    my $gidatadir = ExtUtils::PkgConfig->variable ('gobject-introspection-1.0',
                                                   'gidatadir');
    my $testsdir = $gidatadir . '/tests';
    my %cairo_flags = ExtUtils::PkgConfig->find ('cairo');
    my %gio_flags = ExtUtils::PkgConfig->find ('gio-2.0');
    my %glib_flags = ExtUtils::PkgConfig->find ('glib-2.0');

    # FIXME: Why is --no-as-needed necessary?
       !system (qq(gcc -shared -fPIC -Wl,--no-as-needed -g \\
                   $cairo_flags{cflags} $cairo_flags{libs} \\
                   $gio_flags{cflags} $gio_flags{libs} \\
                   $testsdir/regress.c \\
                   -o libregress.so 1>/dev/null 2>/dev/null))
    && !system (qq(LD_LIBRARY_PATH=$build_dir \\
                   g-ir-scanner \\
                   --include=cairo-1.0 --include=Gio-2.0 \\
                   --namespace=Regress --nsversion=1.0 \\
                   --quiet --warn-all --warn-error \\
                   --library=regress \\
                   --output=Regress-1.0.gir \\
                   $testsdir/regress.h $testsdir/regress.c \\
                   1>/dev/null 2>/dev/null))
    && !system (qq(g-ir-compiler Regress-1.0.gir -o Regress-1.0.typelib \\
                   1>/dev/null 2>/dev/null))
    && !system (qq(gcc -shared -fPIC -g \\
                   $glib_flags{cflags} $glib_flags{libs} \\
                   $testsdir/gimarshallingtests.c \\
                   -o libgimarshallingtests.so 1>/dev/null 2>/dev/null))
    && !system (qq(LD_LIBRARY_PATH=$build_dir \\
                   g-ir-scanner \\
                   --include=GObject-2.0 \\
                   --namespace=GIMarshallingTests \\
                   --symbol-prefix=gi_marshalling_tests --nsversion=1.0 \\
                   --quiet --warn-all --warn-error \\
                   --library=gimarshallingtests \\
                   --output=GIMarshallingTests-1.0.gir \\
                   $testsdir/gimarshallingtests.h $testsdir/gimarshallingtests.c \\
                   1>/dev/null 2>/dev/null))
    && !system (qq(g-ir-compiler GIMarshallingTests-1.0.gir \\
                   -o GIMarshallingTests-1.0.typelib 1>/dev/null 2>/dev/null))
  };

  print $success ? "OK\n" : "not OK\n";

  chdir '..';
}

package MY; # so that "SUPER" works right

sub test {
  my $inherited = shift->SUPER::test(@_);
  # put "build" into LD_LIBRARY_PATH for the tests
  $inherited =~ s/(test_dynamic :: pure_all)\n\t/$1\n\tLD_LIBRARY_PATH=\${LD_LIBRARY_PATH}:build /;
  $inherited;
}

sub postamble {
  return Glib::MakeHelper->postamble_clean ();
}
