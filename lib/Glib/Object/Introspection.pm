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
use warnings;
use Glib;

our $VERSION = 0.001;

use Carp;
$Carp::Internal{(__PACKAGE__)}++;

require XSLoader;
XSLoader::load();

sub setup {
  my ($class, %params) = @_;
  my $basename = $params{basename};
  my $version = $params{version};
  my $package = $params{package};
  my $search_path = $params{search_path} || undef;
  my $name_corrections = $params{name_corrections} || {};
  my $class_static_methods = $params{class_static_methods} || [];

  my %shift_package_name_for = map { $_ => 1 } @$class_static_methods;

  __PACKAGE__->_load_library($basename, $version, $search_path);

  my ($functions, $constants) =
    __PACKAGE__->_register_types($basename, $package);

  no strict qw(refs);
  no warnings qw(redefine prototype);

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
        __PACKAGE__->_invoke($basename,
                             $is_namespaced ? $namespace : undef,
                             $name,
                             @_);
      };
    }
  }

  foreach my $name (@{$constants}) {
    my $auto_name = $package . '::' . $name;
    my $corrected_name = exists $name_corrections->{$auto_name}
      ? $name_corrections->{$auto_name}
      : $auto_name;
    # Install a sub which, on the first invocation, calls _fetch_constant and
    # then overrides itself with a constant sub returning that value.
    *{$corrected_name} = sub () {
      my $value = __PACKAGE__->_fetch_constant($basename, $name);
      {
        *{$corrected_name} = sub () { $value };
      }
      return $value;
    };
  }
}

1;
__END__

=head1 NAME

Glib::Object::Introspection - Dynamically create Perl language bindings

=head1 SYNOPSIS

  use Glib::Object::Introspection;
  Glib::Object::Introspection->setup(
    basename => 'Gtk',
    version => '3.0',
    package => 'Gtk3');
  # now GtkWindow, to mention just one example, is available as
  # Gtk3::Window, and you can call gtk_window_new as Gtk3::Window->new

=head1 ABSTRACT

Glib::Object::Introspection uses the gobject-introspection and libffi projects
to dynamically create Perl bindings for a wide variety of libraries.  Examples
include gtk+, webkit, libsoup and many more.

=head1 DESCRIPTION

To allow Glib::Object::Introspection to create bindings for a library, it must
have installed a typelib file, for example
C<$prefix/lib/girepository-1.0/Gtk-3.0.typelib>.  In your code you then simply
call C<< Glib::Object::Introspection->setup >> to set everything up.  This
method takes a couple of key-value pairs as arguments.  These three are
mandatory:

=over

=item basename => $basename

The basename of the library that should be wrapped.  If your typelib is called
C<Gtk-3.0.typelib>, then the basename is 'Gtk'.

=item version => $version

The particular version of the library that should be wrapped, in string form.
For C<Gtk-3.0.typelib>, it is '3.0'.

=item package => $package

The name of the Perl package where every class and method of the library should
be rooted.  If a library with basename 'Gtk' contains an object 'GtkWindow',
and you pick as the package 'Gtk3', then that object will be available as
'Gtk3::Window'.

=back

The rest are optional:

=over

=item search_path => $search_path

A path that should be used when looking for typelibs.  If you use typelibs from
system directories, or if your environment is set up correctly, then this
should not be necessary.

=item name_corrections => { auto_name => new_name, ... }

A hash ref that is used to rename functions and methods.  Use this if you don't
like the automatically generated mapping for a function or method.  For
example, if C<g_file_hash> is automatically represented as
C<Glib::IO::file_hash> but you want C<Glib::IO::File::hash> then pass

  name_corrections => {
    'Glib::IO::file_hash' => 'Glib::IO::File::hash'
  }

=item class_static_methods => [ functions1, ... ]

An array ref of function names that you want to be treated as class-static
methods.  That is, if you want be able to call
C<Gtk3::Window::list_toplevels> as C<< Gtk3::Window->list_toplevels >>, then
pass

  class_static_methods => [
    'Gtk3::Window::list_toplevels'
  ]

The function names refer to those after name corrections.

=back

=head1 SEE ALSO

=over

=item gobject-introspection: L<http://live.gnome.org/GObjectIntrospection>

=item libffi: L<http://sourceware.org/libffi/>

=back

=head1 AUTHORS

=encoding utf8

=over

=item Emmanuele Bassi <ebassi at linux intel com>

=item muppet <scott asofyet org>

=item Torsten Schönfeld <kaffeetisch at gmx de>

=back

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the terms of the Lesser General Public License (LGPL).  For more information,
see http://www.fsf.org/licenses/lgpl.txt

=cut
