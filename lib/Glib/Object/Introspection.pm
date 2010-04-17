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

package Glib::Object::Introspection;

use strict;
use Glib;

require DynaLoader;
our @ISA = qw(DynaLoader);

our $VERSION = 0.001;
Glib::Object::Introspection->bootstrap ($VERSION);

sub find_registered_namespace {
  my ($class, $namespace) = @_;

  # replace the prefix for unregistered types
  while ($namespace =~ m/^Glib::Object::_Unregistered::\w+/) {
    no strict 'refs';
    my @parents = @{$namespace . '::ISA'};
    $namespace = $parents[-1];
  }

  return $namespace;
}

1;
__END__

=head1 NAME

Glib::Object::Introspection - Dynamically create language bindings

=head1 SYNOPSIS

  XXX

=head1 ABSTRACT

XXX

=head1 DESCRIPTION

XXX

=head1 SEE ALSO

XXX

=head1 AUTHORS

=encoding utf8

XXX

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Torsten Schoenfeld <kaffeetisch@gmx.de>

This library is free software; you can redistribute it and/or modify it under
the terms of the Lesser General Public License (LGPL).  For more information,
see http://www.fsf.org/licenses/lgpl.txt

=cut
