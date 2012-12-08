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

package Glib::Object::Introspection;

use strict;
use warnings;
use Glib;

our $VERSION = '0.013';

use Carp;
$Carp::Internal{(__PACKAGE__)}++;

require XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

my %FORBIDDEN_SUB_NAMES = map { $_ => 1 } qw/AUTOLOAD CLONE DESTROY BEGIN
                                             UNITCHECK CHECK INIT END/;
my @OBJECT_PACKAGES_WITH_VFUNCS;

our %_BASENAME_TO_PACKAGE;
our %_REBLESSERS;

sub _create_invoker_sub {
  my ($basename, $namespace, $name,
      $shift_package_name, $flatten_array_ref_return,
      $handle_sentinel_boolean) = @_;
  if ($flatten_array_ref_return) {
    return sub {
      shift if $shift_package_name;
      my $ref = __PACKAGE__->invoke($basename, $namespace, $name, @_);
      return if not defined $ref;
      return wantarray ? @$ref : $ref->[$#$ref];
    };
  } elsif ($handle_sentinel_boolean) {
    return sub {
      shift if $shift_package_name;
      my ($bool, @stuff) = __PACKAGE__->invoke($basename, $namespace, $name, @_);
      return $bool
        ? @stuff[0..$#stuff] # slice to correctly behave in scalar context
        : ();
    };
  } else {
    return sub {
      shift if $shift_package_name;
      return __PACKAGE__->invoke($basename, $namespace, $name, @_);
    };
  }
}

sub setup {
  my ($class, %params) = @_;
  my $basename = $params{basename};
  my $version = $params{version};
  my $package = $params{package};
  my $search_path = $params{search_path} || undef;
  my $name_corrections = $params{name_corrections} || {};

  $_BASENAME_TO_PACKAGE{$basename} = $package;

  my %shift_package_name_for = exists $params{class_static_methods}
    ? map { $_ => 1 } @{$params{class_static_methods}}
    : ();
  my %flatten_array_ref_return_for = exists $params{flatten_array_ref_return_for}
    ? map { $_ => 1 } @{$params{flatten_array_ref_return_for}}
    : ();
  my %handle_sentinel_boolean_for = exists $params{handle_sentinel_boolean_for}
    ? map { $_ => 1 } @{$params{handle_sentinel_boolean_for}}
    : ();

  if (exists $params{reblessers}) {
    $_REBLESSERS{$_} = $params{reblessers}->{$_}
      for keys %{$params{reblessers}}
  }

  __PACKAGE__->_load_library($basename, $version, $search_path);

  my ($functions, $constants, $fields, $interfaces, $objects_with_vfuncs) =
    __PACKAGE__->_register_types($basename, $package);

  no strict qw(refs);
  no warnings qw(redefine);

  foreach my $namespace (keys %{$functions}) {
    my $is_namespaced = $namespace ne "";
    NAME:
    foreach my $name (@{$functions->{$namespace}}) {
      my $auto_name = $is_namespaced
        ? $package . '::' . $namespace . '::' . $name
        : $package . '::' . $name;
      my $corrected_name = exists $name_corrections->{$auto_name}
        ? $name_corrections->{$auto_name}
        : $auto_name;
      if (defined &{$corrected_name}) {
        next NAME;
      }
      *{$corrected_name} = _create_invoker_sub (
        $basename, $is_namespaced ? $namespace : undef, $name,
        $shift_package_name_for{$corrected_name},
        $flatten_array_ref_return_for{$corrected_name},
        $handle_sentinel_boolean_for{$corrected_name});
    }
  }

  foreach my $name (@{$constants}) {
    my $auto_name = $package . '::' . $name;
    my $corrected_name = exists $name_corrections->{$auto_name}
      ? $name_corrections->{$auto_name}
      : $auto_name;
    # Install a sub which, on the first invocation, calls _fetch_constant and
    # then overrides itself with a constant sub returning that value.
    *{$corrected_name} = sub {
      my $value = __PACKAGE__->_fetch_constant($basename, $name);
      {
        *{$corrected_name} = sub { $value };
      }
      return $value;
    };
  }

  foreach my $namespace (keys %{$fields}) {
    foreach my $field_name (@{$fields->{$namespace}}) {
      my $auto_name = $package . '::' . $namespace . '::' . $field_name;
      my $corrected_name = exists $name_corrections->{$auto_name}
        ? $name_corrections->{$auto_name}
        : $auto_name;
      *{$corrected_name} = sub {
        my ($invocant, $new_value) = @_;
        my $old_value = __PACKAGE__->_get_field($basename, $namespace,
                                                $field_name, $invocant);
        # If a new value is provided, even if it is undef, update the field.
        if (scalar @_ > 1) {
          __PACKAGE__->_set_field($basename, $namespace,
                                  $field_name, $invocant, $new_value);
        }
        return $old_value;
      };
    }
  }

  foreach my $name (@{$interfaces}) {
    my $adder_name = $package . '::' . $name . '::_ADD_INTERFACE';
    *{$adder_name} = sub {
      my ($class, $target_package) = @_;
      __PACKAGE__->_add_interface($basename, $name, $target_package);
    };
  }

  foreach my $object_name (keys %{$objects_with_vfuncs}) {
    my $object_package = $package . '::' . $object_name;
    my $installer_name = $object_package . '::_INSTALL_OVERRIDES';
    *{$installer_name} = sub {
      my ($target_package) = @_;

      # For each vfunc in our ancestry that has an implementation, add a
      # wrapper sub to our immediate parent.
      my @non_perl_parent_packages =
        __PACKAGE__->_find_non_perl_parents($basename, $object_name,
                                            $target_package);
      my $first_parent = $non_perl_parent_packages[0];
      foreach my $parent_package (@non_perl_parent_packages) {
        my @vfuncs = __PACKAGE__->_find_vfuncs_with_implementation(
                       $parent_package, $first_parent);
        VFUNC:
        foreach my $vfunc_names (@vfuncs) {
          my ($vfunc_name, $perl_vfunc_name) = @{$vfunc_names};
          if (exists $FORBIDDEN_SUB_NAMES{$perl_vfunc_name}) {
            $perl_vfunc_name .= '_VFUNC';
          }
          my $full_perl_vfunc_name =
            $first_parent . '::' . $perl_vfunc_name;
          if (defined &{$full_perl_vfunc_name}) {
            next VFUNC;
          }
          *{$full_perl_vfunc_name} = sub {
            __PACKAGE__->_invoke_fallback_vfunc($parent_package,
                                                $vfunc_name,
                                                $first_parent,
                                                @_);
          }
        }
      }

      # Delay hooking up the vfuncs until INIT so that we can see whether the
      # package defines the relevant subs or not.
      push @OBJECT_PACKAGES_WITH_VFUNCS,
           [$basename, $object_name, $target_package];
    };
  }
}

sub INIT {
  no strict qw(refs);
  foreach my $target (@OBJECT_PACKAGES_WITH_VFUNCS) {
    my ($basename, $object_name, $target_package) = @{$target};
    __PACKAGE__->_install_overrides($basename, $object_name, $target_package);
  }
  @OBJECT_PACKAGES_WITH_VFUNCS = ();
}

package Glib::Object::Introspection::_FuncWrapper;

use overload
      '&{}' => sub {
                 my ($func) = @_;
                 return sub { Glib::Object::Introspection::_FuncWrapper::_invoke($func, @_) }
               },
      fallback => 1;

package Glib::Object::Introspection;

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

=head2 C<< Glib::Object::Introspection->setup >>

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

=item class_static_methods => [ function1, ... ]

An array ref of function names that you want to be treated as class-static
methods.  That is, if you want be able to call
C<Gtk3::Window::list_toplevels> as C<< Gtk3::Window->list_toplevels >>, then
pass

  class_static_methods => [
    'Gtk3::Window::list_toplevels'
  ]

The function names refer to those after name corrections.

=item flatten_array_ref_return_for => [ function1, ... ]

An array ref of function names that return an array ref that you want to be
flattened so that they return plain lists.  For example

  flatten_array_ref_return_for => [
    'Gtk3::Window::list_toplevels'
  ]

The function names refer to those after name corrections.  Functions occuring
in C<flatten_array_ref_return_for> may also occur in C<class_static_methods>.

=item handle_sentinel_boolean_for => [ function1, ... ]

An array ref of function names that return multiple values, the first of which
is to be interpreted as indicating whether the rest of the returned values are
valid.  This frequently occurs with functions that have out arguments; the
boolean then indicates whether the out arguments have been written.  With
C<handle_sentinel_boolean_for>, the first return value is taken to be the
sentinel boolean.  If it is true, the rest of the original return values will
be returned, and otherwise an empty list will be returned.

  handle_sentinel_boolean_for => [
    'Gtk3::TreeSelection::get_selected'
  ]

The function names refer to those after name corrections.  Functions occuring
in C<handle_sentinel_boolean_for> may also occur in C<class_static_methods>.

=item reblessers => { package => \&reblesser, ... }

Tells G:O:I to invoke I<reblesser> whenever a Perl object is created for an
object of type I<package>.  Currently, this only applies to boxed unions.  The
reblesser gets passed the pre-created Perl object and needs to return the
modified Perl object.  For example:

  sub Gtk3::Gdk::Event::_rebless {
    my ($event) = @_;
    return bless $event, lookup_real_package_for ($event);
  }

=back

=head2 C<< Glib::Object::Introspection->invoke >>

To invoke specific functions manually, you can use the low-level C<<
Glib::Object::Introspection->invoke >>.

  Glib::Object::Introspection->invoke(
    $basename, $namespace, $function, @args)

=over

=item * $basename is the basename of a library, like 'Gtk'.

=item * $namespace refers to a namespace inside that library, like 'Window'.  Use
undef here if you want to call a library-global function.

=item * $function is the name of the function you want to invoke.  It can also
refer to the name of a constant.

=item * @args are the arguments that should be passed to the function.  For a
method, this should include the invocant.  For a constructor, this should
include the package name.

=back

C<< Glib::Object::Introspection->invoke >> returns whatever the function being
invoked returns.

=head2 Overrides

To override the behavior of a specific function or method, create an
appropriately named sub in the correct package and have it call C<<
Glib::Object::Introspection->invoke >>.  Say you want to override
C<Gtk3::Window::list_toplevels>, then do this:

  sub Gtk3::Window::list_toplevels {
    # ...do something...
    my $ref = Glib::Object::Introspection->invoke (
                'Gtk', 'Window', 'list_toplevels',
                @_);
    # ...do something...
    return wantarray ? @$ref : $ref->[$#$ref];
  }

The sub's name and package must be those after name corrections.

=head2 Converting a Perl variable to a GValue

If you need to marshal into a GValue, then Glib::Object::Introspection cannot
do this automatically because the type information is missing.  If you do have
this information in your module, however, you can use
Glib::Object::Introspection::GValueWrapper to do the conversion.  In the
wrapper for a function that expects a GValue, do this:

  ...
  my $type = ...; # somehow get the package name that
                  # corresponds to the correct GType
  my $real_value =
    Glib::Object::Introspection::GValueWrapper->new ($type, $value);
  # now use Glib::Object::Introspection->invoke and
  # substitute $real_value where you'd use $value
  ...

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
