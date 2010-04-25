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

sub setup {
  my ($class, %params) = @_;
  my $basename = $params{basename};
  my $version = $params{version};
  my $package = $params{package};
  my $name_corrections = $params{name_corrections} || {};
  my $class_static_methods = $params{class_static_methods} || [];

  my %shift_package_name_for = map { $_ => 1 } @$class_static_methods;

  my $functions =
    __PACKAGE__->register_types($basename, $version, $package);

  no strict 'refs';

  foreach my $namespace (keys %{$functions}) {
    my $is_namespaced = $namespace ne "";
    foreach my $name (@{$functions->{$namespace}}) {
      my $auto_name = $is_namespaced
        ? $package . '::' . $namespace . '::' . $name
        : $package . '::' . $name;
      my $corrected_name = exists $name_corrections->{$auto_name}
        ? $name_corrections->{$auto_name}
        : $auto_name;
      *{$corrected_name} = sub {
        shift if $shift_package_name_for{$corrected_name};
        __PACKAGE__->invoke($basename,
                            $is_namespaced ? $namespace : undef,
                            $name,
                            @_);
      };
    }
  }
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
