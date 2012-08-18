/*
 * Copyright (C) 2005 muppet
 * Copyright (C) 2005-2012 Torsten Schoenfeld <kaffeetisch@gmx.de>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by the
 * Free Software Foundation; either version 2.1 of the License, or (at your
 * option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public License
 * for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *
 */

#include "build/gi-version.h"

#include <gperl.h>
#include <gperl_marshal.h>

#include <girepository.h>
#include <girffi.h>

/* #define NOISY */
#ifdef NOISY
# define dwarn(...) warn(__VA_ARGS__)
#else
# define dwarn(...)
#endif

/* ------------------------------------------------------------------------- */

typedef struct {
	ffi_cif *cif;
	ffi_closure *closure;

	GICallableInfo *interface;

	/* either we have a code and data pair, ... */
	SV *code;
	SV *data;

	/* ... or a sub name to be called as a method on the invocant. */
	gchar *sub_name;

	guint data_pos;
	guint destroy_pos;

	gboolean free_after_use;

	gpointer priv; /* perl context */
} GPerlI11nPerlCallbackInfo;

typedef struct {
	GICallableInfo *interface;

	gpointer func;
	gpointer data;
	GDestroyNotify destroy;

	guint data_pos;
	guint destroy_pos;

	SV *data_sv;
} GPerlI11nCCallbackInfo;

typedef struct {
	gsize length;
	guint length_pos;
} GPerlI11nArrayInfo;

/* This stores information that the different marshallers might need to
 * communicate to each other. */
typedef struct {
	GICallableInfo *interface;

	gboolean is_function;
	gboolean is_vfunc;
	gboolean is_callback;

	guint n_args;
	guint n_invoke_args;
	guint n_given_args;
	gboolean is_constructor;
	gboolean is_method;
	gboolean throws;

	gpointer * args;
	ffi_type ** arg_types;
	GIArgument * in_args;
	GIArgument * out_args;
	GITypeInfo ** out_arg_infos;
	GIArgument * aux_args;
	gboolean * is_automatic_arg;

	gboolean has_return_value;
	ffi_type * return_type_ffi;
	GITypeInfo * return_type_info;
	GITransfer return_type_transfer;

	guint current_pos;
	guint method_offset;
	guint stack_offset;
	gint dynamic_stack_offset;

	GSList * callback_infos;
	GSList * free_after_call;

	GSList * array_infos;
} GPerlI11nInvocationInfo;

/* callbacks */
static GPerlI11nPerlCallbackInfo * create_perl_callback_closure_for_named_sub (GITypeInfo *cb_type, gchar *sub_name);
static GPerlI11nPerlCallbackInfo * create_perl_callback_closure (GITypeInfo *cb_type, SV *code);
static void attach_perl_callback_data (GPerlI11nPerlCallbackInfo *info, SV *data);
static void release_perl_callback (gpointer data);

static GPerlI11nCCallbackInfo * create_c_callback_closure (GIBaseInfo *interface, gpointer func);
static void attach_c_callback_data (GPerlI11nCCallbackInfo *info, gpointer data);
static void release_c_callback (gpointer data);

/* invocation */
static void invoke_callback (ffi_cif* cif,
                             gpointer resp,
                             gpointer* args,
                             gpointer userdata);

static void invoke_callable (GICallableInfo *info,
                             gpointer func_pointer,
                             SV **sp, I32 ax, SV **mark, I32 items, /* these correspond to dXSARGS */
                             UV internal_stack_offset);
static gpointer allocate_out_mem (GITypeInfo *arg_type);
static void handle_automatic_arg (guint pos,
                                  GIArgument * arg,
                                  GPerlI11nInvocationInfo * invocation_info);

/* invocation info */
static void prepare_c_invocation_info (GPerlI11nInvocationInfo *iinfo,
                                       GICallableInfo *info,
                                       IV items,
                                       UV internal_stack_offset);
static void clear_c_invocation_info (GPerlI11nInvocationInfo *iinfo);

static void prepare_perl_invocation_info (GPerlI11nInvocationInfo *iinfo,
                                          GICallableInfo *info);
static void clear_perl_invocation_info (GPerlI11nInvocationInfo *iinfo);

/* info finders */
static GIFunctionInfo * get_function_info (GIRepository *repository,
                                           const gchar *basename,
                                           const gchar *namespace,
                                           const gchar *method);
static GIFieldInfo * get_field_info (GIBaseInfo *info,
                                     const gchar *field_name);
static GType get_gtype (GIRegisteredTypeInfo *info);
static const gchar * get_package_for_basename (const gchar *basename);


/* marshallers */
static SV * interface_to_sv (GITypeInfo* info,
                             GIArgument *arg,
                             gboolean own,
                             GPerlI11nInvocationInfo *iinfo);
static void sv_to_interface (GIArgInfo * arg_info,
                             GITypeInfo * type_info,
                             GITransfer transfer,
                             gboolean may_be_null,
                             SV * sv,
                             GIArgument * arg,
                             GPerlI11nInvocationInfo * invocation_info);

static gpointer instance_sv_to_pointer (GICallableInfo *info, SV *sv);

static void sv_to_arg (SV * sv,
                       GIArgument * arg,
                       GIArgInfo * arg_info,
                       GITypeInfo * type_info,
                       GITransfer transfer,
                       gboolean may_be_null,
                       GPerlI11nInvocationInfo * invocation_info);
static SV * arg_to_sv (GIArgument * arg,
                       GITypeInfo * info,
                       GITransfer transfer,
                       GPerlI11nInvocationInfo *iinfo);

static gpointer sv_to_callback (GIArgInfo * arg_info, GITypeInfo * type_info, SV * sv, GPerlI11nInvocationInfo * invocation_info);
static gpointer sv_to_callback_data (SV * sv, GPerlI11nInvocationInfo * invocation_info);

static SV * callback_to_sv (GICallableInfo *interface, gpointer func, GPerlI11nInvocationInfo *invocation_info);
static SV * callback_data_to_sv (gpointer data, GPerlI11nInvocationInfo * invocation_info);

static SV * struct_to_sv (GIBaseInfo* info, GIInfoType info_type, gpointer pointer, gboolean own);
static gpointer sv_to_struct (GITransfer transfer, GIBaseInfo * info, GIInfoType info_type, SV * sv);

static SV * array_to_sv (GITypeInfo *info, gpointer pointer, GITransfer transfer, GPerlI11nInvocationInfo *iinfo);
static gpointer sv_to_array (GITransfer transfer, GITypeInfo *type_info, SV *sv, GPerlI11nInvocationInfo *iinfo);

static SV * glist_to_sv (GITypeInfo* info, gpointer pointer, GITransfer transfer);
static gpointer sv_to_glist (GITransfer transfer, GITypeInfo * type_info, SV * sv);

static SV * ghash_to_sv (GITypeInfo *info, gpointer pointer, GITransfer transfer);
static gpointer sv_to_ghash (GITransfer transfer, GITypeInfo *type_info, SV *sv);

static void raw_to_arg (gpointer raw, GIArgument *arg, GITypeInfo *info);
static void arg_to_raw (GIArgument *arg, gpointer raw, GITypeInfo *info);

/* sizes */
static gsize size_of_type_tag (GITypeTag type_tag);
static gsize size_of_interface (GITypeInfo *type_info);
static gsize size_of_type_info (GITypeInfo *type_info);

/* fields */
static void store_fields (HV *fields, GIBaseInfo *info, GIInfoType info_type);
static SV * get_field (GIFieldInfo *field_info, gpointer mem, GITransfer transfer);
static void set_field (GIFieldInfo *field_info, gpointer mem, GITransfer transfer, SV *value);

/* unions */
static SV * rebless_union_sv (GType type, const char *package, gpointer mem, gboolean own);
static void associate_union_members_with_gtype (GIUnionInfo *info, const gchar *package, GType type);
static GType find_union_member_gtype (const gchar *package, const gchar *namespace);

/* methods */
static void store_methods (HV *namespaced_functions, GIBaseInfo *info, GIInfoType info_type);

/* interface vfuncs */
static void generic_interface_init (gpointer iface, gpointer data);
static void generic_interface_finalize (gpointer iface, gpointer data);

/* object vfuncs */
static void generic_class_init (GIObjectInfo *info, const gchar *target_package, gpointer class);

/* misc. */
#define ccroak(...) call_carp_croak (form (__VA_ARGS__));
static void call_carp_croak (const char *msg);

/* interface_to_sv and its callers might invoke Perl code, so any xsub invoking
 * them needs to save the stack.  this wrapper does this automatically. */
#define SAVED_STACK_SV(expr)			\
	({					\
		SV *_saved_stack_sv;		\
		PUTBACK;			\
		_saved_stack_sv = expr;		\
		SPAGAIN;			\
		_saved_stack_sv;		\
	})

/* ------------------------------------------------------------------------- */

#include "gperl-i11n-callback.c"
#include "gperl-i11n-croak.c"
#include "gperl-i11n-field.c"
#include "gperl-i11n-gvalue.c"
#include "gperl-i11n-info.c"
#include "gperl-i11n-invoke-c.c"
#include "gperl-i11n-invoke-info.c"
#include "gperl-i11n-invoke-perl.c"
#include "gperl-i11n-marshal-arg.c"
#include "gperl-i11n-marshal-array.c"
#include "gperl-i11n-marshal-callback.c"
#include "gperl-i11n-marshal-hash.c"
#include "gperl-i11n-marshal-interface.c"
#include "gperl-i11n-marshal-list.c"
#include "gperl-i11n-marshal-raw.c"
#include "gperl-i11n-marshal-struct.c"
#include "gperl-i11n-method.c"
#include "gperl-i11n-size.c"
#include "gperl-i11n-union.c"
#include "gperl-i11n-vfunc-interface.c"
#include "gperl-i11n-vfunc-object.c"

/* ------------------------------------------------------------------------- */

MODULE = Glib::Object::Introspection	PACKAGE = Glib::Object::Introspection

void
_load_library (class, namespace, version, search_path=NULL)
	const gchar *namespace
	const gchar *version
	const gchar_ornull *search_path
    PREINIT:
	GIRepository *repository;
	GError *error = NULL;
    CODE:
	if (search_path)
		g_irepository_prepend_search_path (search_path);
	repository = g_irepository_get_default ();
	g_irepository_require (repository, namespace, version, 0, &error);
	if (error) {
		gperl_croak_gerror (NULL, error);
	}

void
_register_types (class, namespace, package)
	const gchar *namespace
	const gchar *package
    PREINIT:
	GIRepository *repository;
	gint number, i;
	AV *constants;
	AV *global_functions;
	HV *namespaced_functions;
	HV *fields;
	AV *interfaces;
	HV *objects_with_vfuncs;
    PPCODE:
	repository = g_irepository_get_default ();

	constants = newAV ();
	global_functions = newAV ();
	namespaced_functions = newHV ();
	fields = newHV ();
	interfaces = newAV ();
	objects_with_vfuncs = newHV ();

	number = g_irepository_get_n_infos (repository, namespace);
	for (i = 0; i < number; i++) {
		GIBaseInfo *info;
		GIInfoType info_type;
		const gchar *name;
		gchar *full_package;
		GType type;

		info = g_irepository_get_info (repository, namespace, i);
		info_type = g_base_info_get_type (info);
		name = g_base_info_get_name (info);

		dwarn ("setting up %s.%s\n", namespace, name);

		if (info_type == GI_INFO_TYPE_CONSTANT) {
			av_push (constants, newSVpv (name, PL_na));
		}

		if (info_type == GI_INFO_TYPE_FUNCTION) {
			av_push (global_functions, newSVpv (name, PL_na));
		}

		if (info_type == GI_INFO_TYPE_INTERFACE) {
			av_push (interfaces, newSVpv (name, PL_na));
		}

		if (info_type == GI_INFO_TYPE_OBJECT ||
		    info_type == GI_INFO_TYPE_INTERFACE ||
		    info_type == GI_INFO_TYPE_BOXED ||
		    info_type == GI_INFO_TYPE_STRUCT ||
		    info_type == GI_INFO_TYPE_UNION)
		{
			store_methods (namespaced_functions, info, info_type);
		}

		if (info_type == GI_INFO_TYPE_BOXED ||
		    info_type == GI_INFO_TYPE_STRUCT ||
		    info_type == GI_INFO_TYPE_UNION)
		{
			store_fields (fields, info, info_type);
		}

		if (info_type == GI_INFO_TYPE_OBJECT) {
			store_vfuncs (objects_with_vfuncs, info);
		}

		/* These are the types that we want to register with perl-Glib. */
		if (info_type != GI_INFO_TYPE_OBJECT &&
		    info_type != GI_INFO_TYPE_INTERFACE &&
		    info_type != GI_INFO_TYPE_BOXED &&
		    info_type != GI_INFO_TYPE_STRUCT &&
		    info_type != GI_INFO_TYPE_UNION &&
		    info_type != GI_INFO_TYPE_ENUM &&
		    info_type != GI_INFO_TYPE_FLAGS)
		{
			g_base_info_unref ((GIBaseInfo *) info);
			continue;
		}

		type = get_gtype ((GIRegisteredTypeInfo *) info);
		if (!type) {
			ccroak ("Could not find GType for type %s::%s",
			       namespace, name);
		}
		if (type == G_TYPE_NONE) {
			g_base_info_unref ((GIBaseInfo *) info);
			continue;
		}

		full_package = g_strconcat (package, "::", name, NULL);
		dwarn ("  registering as %s\n", full_package);

		switch (info_type) {
		    case GI_INFO_TYPE_OBJECT:
		    case GI_INFO_TYPE_INTERFACE:
			gperl_register_object (type, full_package);
			break;

		    case GI_INFO_TYPE_BOXED:
		    case GI_INFO_TYPE_STRUCT:
			gperl_register_boxed (type, full_package, NULL);
			break;

		    case GI_INFO_TYPE_UNION:
		    {
			GPerlBoxedWrapperClass *my_wrapper_class;
			GPerlBoxedWrapperClass *default_wrapper_class;
			default_wrapper_class = gperl_default_boxed_wrapper_class ();
			/* FIXME: We leak my_wrapper_class here.  The problem
			 * is that gperl_register_boxed does not copy the
			 * contents of the wrapper class but instead assumes
			 * that the memory passed in will always be valid. */
			my_wrapper_class = g_new (GPerlBoxedWrapperClass, 1);
			*my_wrapper_class = *default_wrapper_class;
			my_wrapper_class->wrap = rebless_union_sv;
			gperl_register_boxed (type, full_package, my_wrapper_class);
			associate_union_members_with_gtype (info, package, type);
			break;
		    }

		    case GI_INFO_TYPE_ENUM:
		    case GI_INFO_TYPE_FLAGS:
			gperl_register_fundamental (type, full_package);
			break;

		    default:
			break;
		}

		g_free (full_package);
		g_base_info_unref ((GIBaseInfo *) info);
	}

	/* Use the empty string as the key to indicate "no namespace". */
	gperl_hv_take_sv (namespaced_functions, "", 0,
	                  newRV_noinc ((SV *) global_functions));

	EXTEND (SP, 4);
	PUSHs (sv_2mortal (newRV_noinc ((SV *) namespaced_functions)));
	PUSHs (sv_2mortal (newRV_noinc ((SV *) constants)));
	PUSHs (sv_2mortal (newRV_noinc ((SV *) fields)));
	PUSHs (sv_2mortal (newRV_noinc ((SV *) interfaces)));
	PUSHs (sv_2mortal (newRV_noinc ((SV *) objects_with_vfuncs)));

# This is only semi-private, as Gtk3 needs it.  But it doesn't seem generally
# applicable, so it doesn't get an import() API.
void
_register_boxed_synonym (class, const gchar *reg_basename, const gchar *reg_name, const gchar *syn_gtype_function)
    PREINIT:
	GIRepository *repository;
	GIBaseInfo *reg_info;
	GModule *module;
	GType (*syn_gtype_function_pointer) (void) = NULL;
	GType reg_type, syn_type;
    CODE:
	repository = g_irepository_get_default ();
	reg_info = g_irepository_find_by_name (repository, reg_basename, reg_name);
	reg_type = reg_info ? get_gtype (reg_info) : 0;
	if (!reg_type)
		croak ("Could not lookup GType for type %s.%s",
		       reg_basename, reg_name);

	/* The GType in question (e.g., GdkRectangle) hasn't been loaded yet,
	 * so we cannot use g_type_name.  It's also absent from the typelib, so
	 * we cannot use g_irepository_find_by_name.  Hence, use the name of
	 * the GType creation function, look it up and call it. */
	module = g_module_open (NULL, 0);
	g_module_symbol (module, syn_gtype_function,
	                 (gpointer *) &syn_gtype_function_pointer);
	syn_type = syn_gtype_function_pointer ? syn_gtype_function_pointer () : 0;
	g_module_close (module);
	if (!syn_type)
		croak ("Could not lookup GType from function %s",
		       syn_gtype_function);

	dwarn ("registering synonym %s => %s",
	       g_type_name (reg_type),
	       g_type_name (syn_type));
	gperl_register_boxed_synonym (reg_type, syn_type);
	g_base_info_unref (reg_info);

SV *
_fetch_constant (class, basename, constant)
	const gchar *basename
	const gchar *constant
    PREINIT:
	GIRepository *repository;
	GIConstantInfo *info;
	GITypeInfo *type_info;
	GIArgument value = {0,};
    CODE:
	repository = g_irepository_get_default ();
	info = g_irepository_find_by_name (repository, basename, constant);
	if (!GI_IS_CONSTANT_INFO (info))
		ccroak ("not a constant");
	type_info = g_constant_info_get_type (info);
	/* FIXME: What am I suppossed to do with the return value? */
	g_constant_info_get_value (info, &value);
	/* No PUTBACK/SPAGAIN needed here. */
	RETVAL = arg_to_sv (&value, type_info, GI_TRANSFER_NOTHING, NULL);
#if GI_CHECK_VERSION (1, 30, 1)
	g_constant_info_free_value (info, &value);
#endif
	g_base_info_unref ((GIBaseInfo *) type_info);
	g_base_info_unref ((GIBaseInfo *) info);
    OUTPUT:
	RETVAL

SV *
_get_field (class, basename, namespace, field, invocant)
	const gchar *basename
	const gchar *namespace
	const gchar *field
	SV *invocant
    PREINIT:
	GIRepository *repository;
	GIBaseInfo *namespace_info;
	GIFieldInfo *field_info;
	GType invocant_type;
	gpointer boxed_mem;
    CODE:
	repository = g_irepository_get_default ();
	namespace_info = g_irepository_find_by_name (repository, basename, namespace);
	if (!namespace_info)
		ccroak ("Could not find information for namespace '%s'",
		        namespace);
	field_info = get_field_info (namespace_info, field);
	if (!field_info)
		ccroak ("Could not find field '%s' in namespace '%s'",
		        field, namespace)
	invocant_type = get_gtype (namespace_info);
	if (invocant_type == G_TYPE_NONE) {
		/* If the invocant has no associated GType, try to look at the
		 * {$package}::_i11n_gtype SV.  It gets set for members of
		 * boxed unions. */
		const gchar *package = get_package_for_basename (basename);
		invocant_type = find_union_member_gtype (package, namespace);
	}
	if (!g_type_is_a (invocant_type, G_TYPE_BOXED))
		ccroak ("Unable to handle access to field '%s' for type '%s'",
		        field, g_type_name (invocant_type));
	boxed_mem = gperl_get_boxed_check (invocant, invocant_type);
	/* No PUTBACK/SPAGAIN needed here. */
	RETVAL = get_field (field_info, boxed_mem, GI_TRANSFER_NOTHING);
	g_base_info_unref (field_info);
	g_base_info_unref (namespace_info);
    OUTPUT:
	RETVAL

void
_set_field (class, basename, namespace, field, invocant, new_value)
	const gchar *basename
	const gchar *namespace
	const gchar *field
	SV *invocant
	SV *new_value
    PREINIT:
	GIRepository *repository;
	GIBaseInfo *namespace_info;
	GIFieldInfo *field_info;
	GType invocant_type;
	gpointer boxed_mem;
    CODE:
	repository = g_irepository_get_default ();
	namespace_info = g_irepository_find_by_name (repository, basename, namespace);
	if (!namespace_info)
		ccroak ("Could not find information for namespace '%s'",
		        namespace);
	field_info = get_field_info (namespace_info, field);
	if (!field_info)
		ccroak ("Could not find field '%s' in namespace '%s'",
		        field, namespace)
	invocant_type = get_gtype (namespace_info);
	if (invocant_type == G_TYPE_NONE) {
		/* If the invocant has no associated GType, try to look at the
		 * {$package}::_i11n_gtype SV.  It gets set for members of
		 * boxed unions. */
		const gchar *package = get_package_for_basename (basename);
		invocant_type = find_union_member_gtype (package, namespace);
	}
	if (!g_type_is_a (invocant_type, G_TYPE_BOXED))
		ccroak ("Unable to handle access to field '%s' for type '%s'",
		        field, g_type_name (invocant_type));
	boxed_mem = gperl_get_boxed_check (invocant, invocant_type);
	/* Conceptually, we need to always transfer ownership to the boxed
	 * object for things like strings.  The memory would then be freed by
	 * the boxed free func.  But to do this correctly, we would need to
	 * free the memory that we are about to abandon by installing a new
	 * pointer.  We can't know what free function to use, though.  So
	 * g_field_info_set_field, and by extension set_field, simply refuse to
	 * set any member that would require such memory management. */
	set_field (field_info, boxed_mem, GI_TRANSFER_EVERYTHING, new_value);
	g_base_info_unref (field_info);
	g_base_info_unref (namespace_info);

void
_add_interface (class, basename, interface_name, target_package)
	const gchar *basename
	const gchar *interface_name
	const gchar *target_package
    PREINIT:
	GIRepository *repository;
	GIInterfaceInfo *info;
	GInterfaceInfo iface_info;
	GType gtype;
    CODE:
	repository = g_irepository_get_default ();
	info = g_irepository_find_by_name (repository, basename, interface_name);
	if (!GI_IS_INTERFACE_INFO (info))
		ccroak ("not an interface");
	iface_info.interface_init = generic_interface_init;
	iface_info.interface_finalize = generic_interface_finalize,
	iface_info.interface_data = info;
	gtype = gperl_object_type_from_package (target_package);
	if (!gtype)
		ccroak ("package '%s' is not registered with Glib-Perl",
		        target_package);
	g_type_add_interface_static (gtype, get_gtype (info), &iface_info);
	/* info is unref'd in generic_interface_finalize */

void
_install_overrides (class, basename, object_name, target_package)
	const gchar *basename
	const gchar *object_name
	const gchar *target_package
    PREINIT:
	GIRepository *repository;
	GIObjectInfo *info;
	GType gtype;
	gpointer klass;
    CODE:
	dwarn ("_install_overrides: %s.%s for %s\n",
	       basename, object_name, target_package);
	repository = g_irepository_get_default ();
	info = g_irepository_find_by_name (repository, basename, object_name);
	if (!GI_IS_OBJECT_INFO (info))
		ccroak ("not an object");
	gtype = gperl_object_type_from_package (target_package);
	if (!gtype)
		ccroak ("package '%s' is not registered with Glib-Perl",
		        target_package);
	klass = g_type_class_peek (gtype);
	if (!klass)
		ccroak ("internal problem: can't peek at type class for %s (%" G_GSIZE_FORMAT ")",
		        g_type_name (gtype), gtype);
	generic_class_init (info, target_package, klass);
	g_base_info_unref (info);

void
_find_non_perl_parents (class, basename, object_name, target_package)
	const gchar *basename
	const gchar *object_name
	const gchar *target_package
    PREINIT:
	GIRepository *repository;
	GIObjectInfo *info;
	GType gtype, object_gtype;
	GQuark reg_quark = g_quark_from_static_string ("__gperl_type_reg");
    PPCODE:
	repository = g_irepository_get_default ();
	info = g_irepository_find_by_name (repository, basename, object_name);
	g_assert (info && GI_IS_OBJECT_INFO (info));
	gtype = gperl_object_type_from_package (target_package);
	object_gtype = get_gtype (info);
	/* find all non-Perl parents up to and including the object type */
	while ((gtype = g_type_parent (gtype))) {
		/* FIXME: we should export gperl_type_reg_quark from Glib */
		if (!g_type_get_qdata (gtype, reg_quark)) {
			const gchar *package = gperl_object_package_from_type (gtype);
			XPUSHs (sv_2mortal (newSVpv (package, PL_na)));
		}
		if (gtype == object_gtype) {
			break;
		}
	}
	g_base_info_unref (info);

void
_find_vfuncs_with_implementation (class, object_package, target_package)
	const gchar *object_package
	const gchar *target_package
    PREINIT:
	GIRepository *repository;
	GType object_gtype, target_gtype;
	gpointer object_klass, target_klass;
	GIObjectInfo *object_info;
	GIStructInfo *struct_info;
	gint n_vfuncs, i;
    PPCODE:
	repository = g_irepository_get_default ();
	target_gtype = gperl_object_type_from_package (target_package);
	object_gtype = gperl_object_type_from_package (object_package);
	g_assert (target_gtype && object_gtype);
	target_klass = g_type_class_peek (target_gtype);
	object_klass = g_type_class_peek (object_gtype);
	g_assert (target_klass && object_klass);
	object_info = g_irepository_find_by_gtype (repository, object_gtype);
	g_assert (object_info && GI_IS_OBJECT_INFO (object_info));
	struct_info = g_object_info_get_class_struct (object_info);
	g_assert (struct_info);
	n_vfuncs = g_object_info_get_n_vfuncs (object_info);
	for (i = 0; i < n_vfuncs; i++) {
		GIVFuncInfo *vfunc_info;
		const gchar *vfunc_name;
		GIFieldInfo *field_info;
		gint field_offset;
		gchar *perl_method_name;
		vfunc_info = g_object_info_get_vfunc (object_info, i);
		vfunc_name = g_base_info_get_name (vfunc_info);
		/* FIXME: g_vfunc_info_get_offset does not seem to work here. */
		field_info = get_field_info (struct_info, vfunc_name);
		g_assert (field_info);
		field_offset = g_field_info_get_offset (field_info);
		perl_method_name = g_ascii_strup (vfunc_name, -1);
		if (G_STRUCT_MEMBER (gpointer, target_klass, field_offset)) {
			AV *av = newAV ();
			av_push (av, newSVpv (vfunc_name, PL_na));
			av_push (av, newSVpv (perl_method_name, PL_na));
			XPUSHs (sv_2mortal (newRV_noinc ((SV *) av)));
		}
		g_free (perl_method_name);
		g_base_info_unref (field_info);
		g_base_info_unref (vfunc_info);
	}
	g_base_info_unref (struct_info);
	g_base_info_unref (object_info);

void
_invoke_fallback_vfunc (class, vfunc_package, vfunc_name, target_package, ...)
	const gchar *vfunc_package
	const gchar *vfunc_name
	const gchar *target_package
    PREINIT:
	UV internal_stack_offset = 4;
	GIRepository *repository;
	GIObjectInfo *info;
	GType gtype;
	gpointer klass;
	GIStructInfo *struct_info;
	GIVFuncInfo *vfunc_info;
	GIFieldInfo *field_info;
	gint field_offset;
	gpointer func_pointer;
    PPCODE:
	dwarn ("_invoke_parent_vfunc: %s.%s, target = %s\n",
	       vfunc_package, vfunc_name, target_package);
	gtype = gperl_object_type_from_package (target_package);
	klass = g_type_class_peek (gtype);
	g_assert (klass);
	repository = g_irepository_get_default ();
	info = g_irepository_find_by_gtype (
		repository, gperl_object_type_from_package (vfunc_package));
	g_assert (info && GI_IS_OBJECT_INFO (info));
	struct_info = g_object_info_get_class_struct (info);
	g_assert (struct_info);
	vfunc_info = g_object_info_find_vfunc (info, vfunc_name);
	g_assert (vfunc_info);
	/* FIXME: g_vfunc_info_get_offset does not seem to work here. */
	field_info = get_field_info (struct_info, vfunc_name);
	g_assert (field_info);
	field_offset = g_field_info_get_offset (field_info);
	func_pointer = G_STRUCT_MEMBER (gpointer, klass, field_offset);
	g_assert (func_pointer);
	invoke_callable (vfunc_info, func_pointer,
	                 sp, ax, mark, items,
	                 internal_stack_offset);
	/* SPAGAIN since invoke_callable probably modified the stack
	 * pointer.  so we need to make sure that our local variable
	 * 'sp' is correct before the implicit PUTBACK happens. */
	SPAGAIN;
	g_base_info_unref (field_info);
	g_base_info_unref (vfunc_info);
	g_base_info_unref (info);

void
invoke (class, basename, namespace, method, ...)
	const gchar *basename
	const gchar_ornull *namespace
	const gchar *method
    PREINIT:
	UV internal_stack_offset = 4;
	GIRepository *repository;
	GIFunctionInfo *info;
	gpointer func_pointer = NULL;
	const gchar *symbol = NULL;
    PPCODE:
	repository = g_irepository_get_default ();
	info = get_function_info (repository, basename, namespace, method);
	symbol = g_function_info_get_symbol (info);
	if (!g_typelib_symbol (g_base_info_get_typelib((GIBaseInfo *) info),
			       symbol, &func_pointer))
	{
		ccroak ("Could not locate symbol %s", symbol);
	}
	invoke_callable (info, func_pointer,
	                 sp, ax, mark, items,
	                 internal_stack_offset);
	/* SPAGAIN since invoke_callable probably modified the stack pointer.
	 * so we need to make sure that our implicit local variable 'sp' is
	 * correct before the implicit PUTBACK happens. */
	SPAGAIN;
	g_base_info_unref ((GIBaseInfo *) info);

# --------------------------------------------------------------------------- #

MODULE = Glib::Object::Introspection	PACKAGE = Glib::Object::Introspection::GValueWrapper

SV *
new (class, const gchar *type_package, SV *perl_value)
    PREINIT:
	GType type;
	GValue *v;
    CODE:
	type = gperl_type_from_package (type_package);
	if (!type)
		ccroak ("Could not find GType for '%s'", type_package);
	v = g_new0 (GValue, 1);
	g_value_init (v, type);
	gperl_value_from_sv (v, perl_value);
	RETVAL = newSVGValueWrapper (v);
    OUTPUT:
	RETVAL

void
DESTROY (SV *sv)
    PREINIT:
	GValue *v;
    CODE:
	v = SvGValueWrapper (sv);
	g_value_unset (v);
	g_free (v);

# --------------------------------------------------------------------------- #

MODULE = Glib::Object::Introspection	PACKAGE = Glib::Object::Introspection::_FuncWrapper

void
_invoke (SV *code, ...)
    PREINIT:
	GPerlI11nCCallbackInfo *wrapper;
	UV internal_stack_offset = 1;
    CODE:
	wrapper = INT2PTR (GPerlI11nCCallbackInfo*, SvIV (SvRV (code)));
	if (!wrapper || !wrapper->func)
		ccroak ("invalid reference encountered");
	invoke_callable (wrapper->interface, wrapper->func,
	                 sp, ax, mark, items,
	                 internal_stack_offset);

void
DESTROY (SV *code)
    PREINIT:
	GPerlI11nCCallbackInfo *info;
    CODE:
	info = INT2PTR (GPerlI11nCCallbackInfo*, SvIV (SvRV (code)));
	if (info)
		release_c_callback (info);
