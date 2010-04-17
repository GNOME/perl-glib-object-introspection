# Copyright (C) 2010 Torsten Schoenfeld <kaffeetisch@gmx.de>
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
# 59 Temple Place - Suite 330, Boston, MA 02111-1307 USA.

BEGIN { require 5.008; }

use strict;
use warnings;
use ExtUtils::MakeMaker;
use File::Spec;
use Cwd;

my %PREREQ_PM = (
  'ExtUtils::Depends'   => 0.300,
  'ExtUtils::PkgConfig' => 1.000,
  'Glib'                => 1.220,
);

my %BUILD_REQ = (
  'gobject-introspection-1.0' => '0.6.10',
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
      package => 'MY',
    },
  },

  $deps->get_makefile_vars,
);

sub MY::postamble
{
  return Glib::MakeHelper->postamble_clean ();
}
