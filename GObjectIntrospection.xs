/*
 * Copyright (C) 2005 muppet
 * Copyright (C) 2005-2010 Torsten Schoenfeld <kaffeetisch@gmx.de>
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
 * Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
 *
 */

#include "gperl.h"
#include "gperl_marshal.h"

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

	SV *code;
	SV *data;

	gint data_pos;
	gint notify_pos;

	gboolean free_after_use;

	gpointer priv; /* perl context */
} GPerlI11nCallbackInfo;

/* This stores information that one call to sv_to_arg needs to make available
 * to later calls of sv_to_arg. */
typedef struct {
	gint current_pos;
	GSList * callback_infos;
	GSList * free_after_call;
} GPerlI11nInvocationInfo;

static GPerlI11nCallbackInfo* create_callback_closure (GITypeInfo *cb_type, SV *code);
static void attach_callback_data (GPerlI11nCallbackInfo *info, SV *data);

static void invoke_callback (ffi_cif* cif, gpointer resp, gpointer* args, gpointer userdata);
static void release_callback (gpointer data);

/* ------------------------------------------------------------------------- */

/* Caller owns return value */
static GIFunctionInfo *
get_function_info (GIRepository *repository,
                   const gchar *basename,
                   const gchar *namespace,
                   const gchar *method)
{
	dwarn ("%s: %s, %s, %s\n", G_STRFUNC, basename, namespace, method);

	if (namespace) {
		GIBaseInfo *namespace_info = g_irepository_find_by_name (
			repository, basename, namespace);
		if (!namespace_info)
			croak ("Can't find information for namespace %s",
			       namespace);

		GIFunctionInfo *function_info = NULL;
		switch (g_base_info_get_type (namespace_info)) {
		    case GI_INFO_TYPE_OBJECT:
			function_info = g_object_info_find_method (
				(GIObjectInfo *) namespace_info,
				method);
			break;
		    case GI_INFO_TYPE_INTERFACE:
			function_info = g_interface_info_find_method (
				(GIInterfaceInfo *) namespace_info,
				method);
			break;
		    case GI_INFO_TYPE_BOXED:
		    case GI_INFO_TYPE_STRUCT:
			function_info = g_struct_info_find_method (
				(GIStructInfo *) namespace_info,
				method);
			break;
		    default:
			croak ("Base info for namespace %s has incorrect type",
			       namespace);
		}

		if (!function_info)
			croak ("Can't find information for method "
			       "%s::%s", namespace, method);

		g_base_info_unref (namespace_info);

		return function_info;
	} else {
		GIBaseInfo *method_info = g_irepository_find_by_name (
			repository, basename, method);

		if (!method_info)
			croak ("Can't find information for method %s", method);

		switch (g_base_info_get_type (method_info)) {
		    case GI_INFO_TYPE_FUNCTION:
			return (GIFunctionInfo *) method_info;
		    default:
			croak ("Base info for method %s has incorrect type",
			       method);
		}
	}

	return NULL;
}

/* ------------------------------------------------------------------------- */

static gpointer
handle_callback_arg (GIArgInfo * arg_info,
                     GITypeInfo * type_info,
                     SV * sv,
                     GPerlI11nInvocationInfo * invocation_info)
{
	GPerlI11nCallbackInfo *callback_info;

	GSList *l;
	for (l = invocation_info->callback_infos; l != NULL; l = l->next) {
		GPerlI11nCallbackInfo *callback_info = l->data;
		if (invocation_info->current_pos == callback_info->notify_pos) {
			dwarn ("      destroy notify for callback %p\n",
			       callback_info);
			return release_callback;
		}
	}

	callback_info = create_callback_closure (type_info, sv);
	callback_info->data_pos = g_arg_info_get_closure (arg_info);
	callback_info->notify_pos = g_arg_info_get_destroy (arg_info);
	callback_info->free_after_use = FALSE;

	switch (g_arg_info_get_scope (arg_info)) {
	    case GI_SCOPE_TYPE_CALL:
		dwarn ("      callback has scope 'call'\n");
		invocation_info->free_after_call
			= g_slist_prepend (invocation_info->free_after_call,
			                   callback_info);
		break;
	    case GI_SCOPE_TYPE_NOTIFIED:
		dwarn ("      callback has scope 'notified'\n");
		/* This case is already taken care of by the notify
		 * stuff above */
		break;
	    case GI_SCOPE_TYPE_ASYNC:
		dwarn ("      callback has scope 'async'\n");
		/* FIXME: callback_info->free_after_use = TRUE; */
		break;
	    default:
		croak ("unhandled scope type %d encountered",
		       g_arg_info_get_scope (arg_info));
	}

	invocation_info->callback_infos =
		g_slist_prepend (invocation_info->callback_infos,
		                 callback_info);

	dwarn ("      returning closure %p from info %p\n",
	       callback_info->closure, callback_info);
	return callback_info->closure;
}

static gpointer
handle_void_arg (GIArgInfo * arg_info,
                 GITypeInfo * type_info,
                 SV * sv,
                 GPerlI11nInvocationInfo * invocation_info)
{
	gpointer pointer = NULL;
	gboolean is_user_data = FALSE;
	GSList *l;
	dwarn ("    type %p -> void pointer\n", type_info);
	for (l = invocation_info->callback_infos; l != NULL; l = l->next) {
		GPerlI11nCallbackInfo *callback_info = l->data;
		if (callback_info->data_pos == invocation_info->current_pos) {
			is_user_data = TRUE;
			dwarn ("      user data for callback %p\n",
			       callback_info);
			attach_callback_data (callback_info, sv);
			pointer = callback_info;
			break; /* out of the for loop */
		}
	}
	if (!is_user_data)
		croak ("encountered void pointer that is not "
		       "callback user data");
	return pointer;
}

/* ------------------------------------------------------------------------- */

static gpointer
sv_to_pointer (GIArgInfo * arg_info,
               GITypeInfo * type_info,
               SV * sv,
               GPerlI11nInvocationInfo * invocation_info)
{
	GIBaseInfo *interface;
	GIInfoType info_type;

	interface = g_type_info_get_interface (type_info);
	if (!interface)
		croak ("Could not convert sv %p to pointer", sv);
	info_type = g_base_info_get_type (interface);

	dwarn ("    interface %p (%s) of type %d\n",
	       interface, g_base_info_get_name (interface), info_type);

	gpointer pointer = NULL;

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		pointer = gperl_get_object (sv);
		break;

	    case GI_INFO_TYPE_UNION:
	    case GI_INFO_TYPE_STRUCT:
	    case GI_INFO_TYPE_BOXED:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		if (!type)
			croak ("Could not find GType for boxed/struct/union type %s::%s",
			       g_base_info_get_namespace (interface),
			       g_base_info_get_name (interface));
		dwarn ("    struct gtype %s (%d)\n",
		       g_type_name (type), type);
		pointer = gperl_get_boxed_check (sv, type);
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		pointer = GINT_TO_POINTER (gperl_convert_enum (type, sv));
		break;
	    }

	    case GI_INFO_TYPE_FLAGS:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		pointer = GUINT_TO_POINTER (gperl_convert_flags (type, sv));
		break;
	    }

	    case GI_INFO_TYPE_CALLBACK:
		pointer = handle_callback_arg (arg_info, type_info, sv,
		                               invocation_info);
		break;

	    default:
		croak ("sv_to_pointer: Don't know how to handle info type %d", info_type);
	}

	g_base_info_unref ((GIBaseInfo *) interface);

	return pointer;
}

static SV *
pointer_to_sv (GITypeInfo* info, gpointer pointer, gboolean own)
{
	GIBaseInfo *interface;
	GIInfoType info_type;

	dwarn ("  pointer_to_sv: pointer %p, info %p\n",
	       pointer, info);

	if (!pointer)
		return &PL_sv_undef;

	interface = g_type_info_get_interface (info);
	if (!interface)
		croak ("Could not convert pointer %p to SV", pointer);
	info_type = g_base_info_get_type (interface);
	dwarn ("    info type: %d\n", info_type);

	SV *sv = NULL;

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		sv = gperl_new_object (pointer, own);
		break;

	    case GI_INFO_TYPE_UNION:
	    case GI_INFO_TYPE_STRUCT:
	    case GI_INFO_TYPE_BOXED:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		if (!type)
			croak ("Could not find GType for boxed/struct/union type %s::%s",
			       g_base_info_get_namespace (interface),
			       g_base_info_get_name (interface));
		dwarn ("    boxed type: %d (%s)\n", type, g_type_name (type));
		sv = gperl_new_boxed (pointer, type, own);
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		sv = gperl_convert_back_enum (type, GPOINTER_TO_INT (pointer));
		break;
	    }

	    case GI_INFO_TYPE_FLAGS:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		sv = gperl_convert_back_flags (type, GPOINTER_TO_UINT (pointer));
		break;
	    }

	    default:
		croak ("pointer_to_sv: Don't know how to handle info type %d", info_type);
	}

	g_base_info_unref ((GIBaseInfo *) interface);

	return sv;
}

static gpointer
instance_sv_to_pointer (GIFunctionInfo *function_info, SV *sv)
{
	// We do *not* own container.
	GIBaseInfo *container = g_base_info_get_container (
				  (GIBaseInfo *) function_info);
	GIInfoType info_type = g_base_info_get_type (container);

	dwarn ("  instance_sv_to_pointer: container name: %s, info type: %d\n",
	       g_base_info_get_name (container),
	       info_type);

	gpointer pointer = NULL;

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		pointer = gperl_get_object (sv);
		dwarn ("    -> object pointer: %p\n", pointer);
		break;

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    {
		GType type = g_registered_type_info_get_g_type (
			       (GIRegisteredTypeInfo *) container);
		pointer = gperl_get_boxed_check (sv, type);
		dwarn ("    -> boxed pointer: %p\n", pointer);
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    case GI_INFO_TYPE_FLAGS:
	    case GI_INFO_TYPE_CALLBACK:
	    case GI_INFO_TYPE_UNRESOLVED:
	    default:
		croak ("instance_sv_to_pointer: Don't know how to handle info type %d", info_type);
	}

	return pointer;
}

static void
sv_to_arg (SV * sv,
           GArgument * arg,
           GIArgInfo * arg_info,
           GITypeInfo * type_info,
           gboolean may_be_null,
           GPerlI11nInvocationInfo * invocation_info)
{
	GITypeTag tag = g_type_info_get_tag (type_info);

	if (!sv || !SvOK (sv))
		/* Interfaces need to be able to handle undef separately. */
		if (!may_be_null && tag != GI_TYPE_TAG_INTERFACE)
			croak ("undefined value for a mandatory argument encountered");

	switch (tag) {
	    case GI_TYPE_TAG_VOID:
		arg->v_pointer = handle_void_arg (arg_info, type_info, sv,
		                                  invocation_info);
		break;

	    case GI_TYPE_TAG_BOOLEAN:
		arg->v_boolean = SvTRUE (sv);
		break;

	    case GI_TYPE_TAG_INT8:
		arg->v_int8 = (gint8) SvIV (sv);
		break;

	    case GI_TYPE_TAG_UINT8:
		arg->v_uint8 = (guint8) SvUV (sv);
		break;

	    case GI_TYPE_TAG_INT16:
		arg->v_int16 = (gint16) SvIV (sv);
		break;

	    case GI_TYPE_TAG_UINT16:
		arg->v_uint16 = (guint16) SvUV (sv);
		break;

	    case GI_TYPE_TAG_INT32:
		arg->v_int32 = (gint32) SvIV (sv);
		break;

	    case GI_TYPE_TAG_UINT32:
		arg->v_uint32 = (guint32) SvUV (sv);
		break;

	    case GI_TYPE_TAG_INT64:
		arg->v_int64 = SvGInt64 (sv);
		break;

	    case GI_TYPE_TAG_UINT64:
		arg->v_uint64 = SvGUInt64 (sv);
		break;

	    case GI_TYPE_TAG_FLOAT:
		arg->v_float = (gfloat) SvNV (sv);
		break;

	    case GI_TYPE_TAG_DOUBLE:
		arg->v_double = SvNV (sv);
		break;

	    case GI_TYPE_TAG_INT:
		arg->v_int = SvIV (sv);
		break;

	    case GI_TYPE_TAG_UINT:
		arg->v_uint = SvUV (sv);
		break;

	    case GI_TYPE_TAG_LONG:
		arg->v_long = SvIV (sv);
		break;

	    case GI_TYPE_TAG_ULONG:
		arg->v_ulong = SvUV (sv);
		break;

	    case GI_TYPE_TAG_ARRAY:
		croak ("FIXME - GI_TYPE_TAG_ARRAY");
		break;

	    case GI_TYPE_TAG_INTERFACE:
		dwarn ("    type %p -> interface\n", type_info);
		arg->v_pointer = sv_to_pointer (arg_info, type_info, sv,
		                                invocation_info);
		break;

	    case GI_TYPE_TAG_GLIST:
		croak ("FIXME - GI_TYPE_TAG_GLIST");
		break;

	    case GI_TYPE_TAG_GSLIST:
		croak ("FIXME - GI_TYPE_TAG_GSLIST");
		break;

	    case GI_TYPE_TAG_GHASH:
		croak ("FIXME - GI_TYPE_TAG_GHASH");
		break;

	    case GI_TYPE_TAG_ERROR:
		croak ("FIXME - A GError as an in/inout arg?  Should never happen!");
		break;

	    case GI_TYPE_TAG_SSIZE:
		arg->v_ssize = (gssize) SvIV (sv);
		break;

	    case GI_TYPE_TAG_SIZE:
		arg->v_size = (gsize) SvUV (sv);
		break;

	    case GI_TYPE_TAG_UTF8:
		arg->v_string = SvOK (sv) ? SvGChar (sv) : NULL;
		break;

	    case GI_TYPE_TAG_FILENAME:
		arg->v_string = SvOK (sv) ? gperl_filename_from_sv (sv) : NULL;
		break;

	    default:
		croak ("Unhandled info tag %d", tag);
	}
}

static SV *
arg_to_sv (const GArgument * arg,
	   GITypeInfo * info,
           GITransfer transfer)
{
	GITypeTag tag = g_type_info_get_tag (info);
	gboolean own = transfer == GI_TRANSFER_EVERYTHING;

	dwarn ("  arg_to_sv: info %p with type tag %d (%s)\n",
	       info, tag, g_type_tag_to_string (tag));

	switch (tag) {
	    case GI_TYPE_TAG_VOID:
		return NULL;

	    case GI_TYPE_TAG_BOOLEAN:
		return boolSV (arg->v_boolean);

	    case GI_TYPE_TAG_INT8:
		return newSViv (arg->v_int8);

	    case GI_TYPE_TAG_UINT8:
		return newSVuv (arg->v_uint8);

	    case GI_TYPE_TAG_INT16:
		return newSViv (arg->v_int16);

	    case GI_TYPE_TAG_UINT16:
		return newSVuv (arg->v_uint16);

	    case GI_TYPE_TAG_INT32:
		return newSViv (arg->v_int32);

	    case GI_TYPE_TAG_UINT32:
		return newSVuv (arg->v_uint32);

	    case GI_TYPE_TAG_INT64:
		return newSVGInt64 (arg->v_int64);

	    case GI_TYPE_TAG_UINT64:
		return newSVGUInt64 (arg->v_uint64);

	    case GI_TYPE_TAG_FLOAT:
		return newSVnv (arg->v_float);

	    case GI_TYPE_TAG_DOUBLE:
		return newSVnv (arg->v_double);

	    case GI_TYPE_TAG_INT:
		return newSViv (arg->v_int);

	    case GI_TYPE_TAG_UINT:
		return newSVuv (arg->v_uint);

	    case GI_TYPE_TAG_LONG:
		return newSViv (arg->v_long);

	    case GI_TYPE_TAG_ULONG:
		return newSVuv (arg->v_ulong);

	    case GI_TYPE_TAG_ARRAY:
		croak ("FIXME - GI_TYPE_TAG_ARRAY");

	    case GI_TYPE_TAG_INTERFACE:
		return pointer_to_sv (info, arg->v_pointer, own);

	    case GI_TYPE_TAG_GLIST:
	    {
		GITypeInfo *param_info;
		GList *i;
		AV *av;
		SV *value;

		param_info = g_type_info_get_param_type (info, 0);
		av = newAV ();

		dwarn ("    GList: pointer %p, param_info %p with type tag %d\n",
		      arg->v_pointer,
		      param_info,
		      g_type_info_get_tag (param_info));

		for (i = arg->v_pointer; i; i = i->next) {
			dwarn ("      converting pointer %p\n", i->data);
			value = pointer_to_sv (param_info, i->data, transfer);
			if (value)
				av_push (av, value);
		}

		if (transfer >= GI_TRANSFER_CONTAINER)
			g_list_free (arg->v_pointer);

		g_base_info_unref ((GIBaseInfo *) param_info);

		return newRV_noinc ((SV *) av);
	    }

	    case GI_TYPE_TAG_GSLIST:
		croak ("FIXME - GI_TYPE_TAG_GSLIST");

	    case GI_TYPE_TAG_GHASH:
		croak ("FIXME - GI_TYPE_TAG_GHASH");

	    case GI_TYPE_TAG_ERROR:
		croak ("FIXME - GI_TYPE_TAG_ERROR");
		break;

	    case GI_TYPE_TAG_SSIZE:
		return newSViv (arg->v_ssize);

	    case GI_TYPE_TAG_SIZE:
		return newSVuv (arg->v_size);

	    case GI_TYPE_TAG_UTF8:
	    {
		SV *sv = newSVGChar (arg->v_string);
		if (own)
			g_free (arg->v_string);
		return sv;
	    }

	    case GI_TYPE_TAG_FILENAME:
	    {
		SV *sv = gperl_sv_from_filename (arg->v_string);
		if (own)
			g_free (arg->v_string);
		return sv;
	    }

	    default:
		croak ("Unhandled info tag %d", tag);
	}

	return NULL;
}

/* ------------------------------------------------------------------------- */

#define CAST_RAW(raw, type) (*((type *) raw))

static void
raw_to_arg (gpointer raw, GArgument *arg, GITypeInfo *info)
{
	GITypeTag tag = g_type_info_get_tag (info);

	switch (tag) {
	    case GI_TYPE_TAG_VOID:
		/* do nothing */
		break;

	    case GI_TYPE_TAG_BOOLEAN:
		arg->v_boolean = CAST_RAW (raw, gboolean);
		break;

	    case GI_TYPE_TAG_INT8:
		arg->v_int8 = CAST_RAW (raw, gint8);
		break;

	    case GI_TYPE_TAG_UINT8:
		arg->v_uint8 = CAST_RAW (raw, guint8);
		break;

	    case GI_TYPE_TAG_INT16:
		arg->v_int16 = CAST_RAW (raw, gint16);
		break;

	    case GI_TYPE_TAG_UINT16:
		arg->v_uint16 = CAST_RAW (raw, guint16);
		break;

	    case GI_TYPE_TAG_INT32:
		arg->v_int32 = CAST_RAW (raw, gint32);
		break;

	    case GI_TYPE_TAG_UINT32:
		arg->v_uint32 = CAST_RAW (raw, guint32);
		break;

	    case GI_TYPE_TAG_INT64:
		arg->v_int64 = CAST_RAW (raw, gint64);
		break;

	    case GI_TYPE_TAG_UINT64:
		arg->v_uint64 = CAST_RAW (raw, guint64);
		break;

	    case GI_TYPE_TAG_FLOAT:
		arg->v_float = CAST_RAW (raw, gfloat);
		break;

	    case GI_TYPE_TAG_DOUBLE:
		arg->v_double = CAST_RAW (raw, gdouble);
		break;

	    case GI_TYPE_TAG_INT:
		arg->v_int = CAST_RAW (raw, gint);
		break;

	    case GI_TYPE_TAG_UINT:
		arg->v_uint = CAST_RAW (raw, guint);
		break;

	    case GI_TYPE_TAG_LONG:
		arg->v_long = CAST_RAW (raw, glong);
		break;

	    case GI_TYPE_TAG_ULONG:
		arg->v_ulong = CAST_RAW (raw, gulong);
		break;

	    case GI_TYPE_TAG_ARRAY:
	    case GI_TYPE_TAG_INTERFACE:
	    case GI_TYPE_TAG_GLIST:
	    case GI_TYPE_TAG_GSLIST:
	    case GI_TYPE_TAG_GHASH:
	    case GI_TYPE_TAG_ERROR:
		arg->v_pointer = * (gpointer *) raw;
		break;

	    case GI_TYPE_TAG_SSIZE:
		arg->v_ssize = CAST_RAW (raw, gssize);
		break;

	    case GI_TYPE_TAG_SIZE:
		arg->v_size = CAST_RAW (raw, gsize);
		break;

	    case GI_TYPE_TAG_UTF8:
	    case GI_TYPE_TAG_FILENAME:
		arg->v_string = * (gchar **) raw;
		break;

	    default:
		croak ("Unhandled info tag %d", tag);
	}
}

static void
arg_to_raw (GArgument *arg, gpointer raw, GITypeInfo *info)
{
	GITypeTag tag = g_type_info_get_tag (info);

	switch (tag) {
	    case GI_TYPE_TAG_VOID:
		/* do nothing */
		break;

	    case GI_TYPE_TAG_BOOLEAN:
		* (gboolean *) raw = arg->v_boolean;
		break;

	    case GI_TYPE_TAG_INT8:
		* (gint8 *) raw = arg->v_int8;
		break;

	    case GI_TYPE_TAG_UINT8:
		* (guint8 *) raw = arg->v_uint8;
		break;

	    case GI_TYPE_TAG_INT16:
		* (gint16 *) raw = arg->v_int16;
		break;

	    case GI_TYPE_TAG_UINT16:
		* (guint16 *) raw = arg->v_uint16;
		break;

	    case GI_TYPE_TAG_INT32:
		* (gint32 *) raw = arg->v_int32;
		break;

	    case GI_TYPE_TAG_UINT32:
		* (guint32 *) raw = arg->v_uint32;
		break;

	    case GI_TYPE_TAG_INT64:
		* (gint64 *) raw = arg->v_int64;
		break;

	    case GI_TYPE_TAG_UINT64:
		* (guint64 *) raw = arg->v_uint64;
		break;

	    case GI_TYPE_TAG_FLOAT:
		* (gfloat *) raw = arg->v_float;
		break;

	    case GI_TYPE_TAG_DOUBLE:
		* (gdouble *) raw = arg->v_double;
		break;

	    case GI_TYPE_TAG_INT:
		* (gint *) raw = arg->v_int;
		break;

	    case GI_TYPE_TAG_UINT:
		* (guint *) raw = arg->v_uint;
		break;

	    case GI_TYPE_TAG_LONG:
		* (glong *) raw = arg->v_long;
		break;

	    case GI_TYPE_TAG_ULONG:
		* (gulong *) raw = arg->v_ulong;
		break;

	    case GI_TYPE_TAG_ARRAY:
	    case GI_TYPE_TAG_INTERFACE:
	    case GI_TYPE_TAG_GLIST:
	    case GI_TYPE_TAG_GSLIST:
	    case GI_TYPE_TAG_GHASH:
	    case GI_TYPE_TAG_ERROR:
		* (gpointer *) raw = arg->v_pointer;
		break;

	    case GI_TYPE_TAG_SSIZE:
		* (gssize *) raw = arg->v_ssize;
		break;

	    case GI_TYPE_TAG_SIZE:
		* (gsize *) raw = arg->v_size;
		break;

	    case GI_TYPE_TAG_UTF8:
	    case GI_TYPE_TAG_FILENAME:
		* (gchar **) raw = arg->v_string;
		break;

	    default:
		croak ("Unhandled info tag %d", tag);
	}
}

static GPerlI11nCallbackInfo *
create_callback_closure (GITypeInfo *cb_type, SV *code)
{
	GPerlI11nCallbackInfo *info;

	info = g_new0 (GPerlI11nCallbackInfo, 1);
	info->interface =
		(GICallableInfo *) g_type_info_get_interface (cb_type);
	info->cif = g_new0 (ffi_cif, 1);
	info->closure =
		g_callable_info_prepare_closure (info->interface, info->cif,
		                                 invoke_callback, info);
	info->code = newSVsv (code);

#ifdef PERL_IMPLICIT_CONTEXT
	info->priv = aTHX;
#endif

	return info;
}

static void
attach_callback_data (GPerlI11nCallbackInfo *info, SV *data)
{
	info->data = newSVsv (data);
}

static void
invoke_callback (ffi_cif* cif, gpointer resp, gpointer* args, gpointer userdata)
{
	GPerlI11nCallbackInfo *info;
	GICallableInfo *cb_interface;
	int n_args, i;
	int in_inout;
	GITypeInfo *return_type;
	gboolean have_return_type;
	int n_return_values;
	I32 context;
	dGPERL_CALLBACK_MARSHAL_SP;

	/* unwrap callback info struct from userdata */
	info = (GPerlI11nCallbackInfo *) userdata;
	cb_interface = (GICallableInfo *) info->interface;

	/* set perl context */
	GPERL_CALLBACK_MARSHAL_INIT (info);

	ENTER;
	SAVETMPS;

	PUSHMARK (SP);

	/* find arguments; use type information from interface to find in and
	 * in-out args and their types, count in-out and out args, and find
	 * suitable converters; push in and in-out arguments onto the perl
	 * stack */
	in_inout = 0;
	n_args = g_callable_info_get_n_args (cb_interface);
	for (i = 0; i < n_args; i++) {
		GIArgInfo *arg_info = g_callable_info_get_arg (cb_interface, i);
		GITypeInfo *arg_type = g_arg_info_get_type (arg_info);
		GITransfer transfer = g_arg_info_get_ownership_transfer (arg_info);
		GIDirection direction = g_arg_info_get_direction (arg_info);

		dwarn ("arg info: %p\n"
		       "  direction: %d\n"
		       "  is dipper: %d\n"
		       "  is return value: %d\n"
		       "  is optional: %d\n"
		       "  may be null: %d\n"
		       "  transfer: %d\n",
		       arg_info,
		       g_arg_info_get_direction (arg_info),
		       g_arg_info_is_dipper (arg_info),
		       g_arg_info_is_return_value (arg_info),
		       g_arg_info_is_optional (arg_info),
		       g_arg_info_may_be_null (arg_info),
		       g_arg_info_get_ownership_transfer (arg_info));

		dwarn ("arg type: %p\n"
		       "  is pointer: %d\n"
		       "  tag: %d\n",
		       arg_type,
		       g_type_info_is_pointer (arg_type),
		       g_type_info_get_tag (arg_type));

		if (direction == GI_DIRECTION_IN ||
		    direction == GI_DIRECTION_INOUT)
		{
			GArgument arg;
			raw_to_arg (args[i], &arg, arg_type);
			XPUSHs (sv_2mortal (arg_to_sv (&arg, arg_type, transfer)));
		}

		if (direction == GI_DIRECTION_INOUT ||
		    direction == GI_DIRECTION_OUT)
		{
			in_inout++;
		}

		g_base_info_unref ((GIBaseInfo *) arg_info);
		g_base_info_unref ((GIBaseInfo *) arg_type);
	}

	/* push user data onto the Perl stack */
	if (info->data)
		XPUSHs (sv_2mortal (newSVsv (info->data)));

	PUTBACK;

	/* determine suitable Perl call context; return_type is freed further
	 * below */
	return_type = g_callable_info_get_return_type (cb_interface);
	have_return_type =
		GI_TYPE_TAG_VOID != g_type_info_get_tag (return_type);

	context = G_VOID | G_DISCARD;
	if (have_return_type) {
		context = in_inout > 0
		  ? G_ARRAY
		  : G_SCALAR;
	} else {
		if (in_inout == 1) {
			context = G_SCALAR;
		} else if (in_inout > 1) {
			context = G_ARRAY;
		}
	}

	/* do the call, demand #in-out+#out+#return-value return values */
	n_return_values = have_return_type
	  ? in_inout + 1
	  : in_inout;
	if (n_return_values == 0) {
		call_sv (info->code, context);
	} else {
		int n_returned = call_sv (info->code, context);
		if (n_returned != n_return_values) {
			croak ("callback returned %d values "
			       "but is supposed to return %d values",
			       n_returned, n_return_values);
		}
	}

	SPAGAIN;

	/* convert in-out and out values and stuff them back into args */
	if (in_inout > 0) {
		SV **returned_values;
		int out_index;

		returned_values = g_new0 (SV *, in_inout);

		/* pop scalars off the stack and put them into the array;
		 * reverse the order since POPs pops items off of the end of
		 * the stack. */
		for (i = 0; i < in_inout; i++) {
			/* FIXME: Does this leak the sv?  Should we check the
			 * transfer setting? */
			returned_values[in_inout - i - 1] = newSVsv (POPs);
		}

		out_index = 0;
		for (i = 0; i < n_args; i++) {
			GIArgInfo *arg_info = g_callable_info_get_arg (cb_interface, i);
			GITypeInfo *arg_type = g_arg_info_get_type (arg_info);
			GIDirection direction = g_arg_info_get_direction (arg_info);
			gboolean may_be_null = g_arg_info_may_be_null (arg_info);

			if (direction == GI_DIRECTION_INOUT ||
			    direction == GI_DIRECTION_OUT)
			{
				GArgument tmp_arg;
				sv_to_arg (returned_values[out_index], &tmp_arg, arg_info, arg_type, may_be_null, NULL);
				arg_to_raw (&tmp_arg, args[i], arg_type);
				out_index++;
			}
		}

		g_free (returned_values);
	}

	/* store return value in resp, if any */
	if (have_return_type) {
		GArgument arg;
		GITypeInfo *type_info;
		gboolean may_be_null;

		type_info = g_callable_info_get_return_type (cb_interface);
		may_be_null = g_callable_info_may_return_null (cb_interface);

		dwarn ("ret type: %p\n"
		       "  is pointer: %d\n"
		       "  tag: %d\n",
		       type_info,
		       g_type_info_is_pointer (type_info),
		       g_type_info_get_tag (type_info));

		/* FIXME: Does this leak the sv?  Should we check the transfer
		 * setting? */
		sv_to_arg (newSVsv (POPs), &arg, NULL, type_info, may_be_null, NULL);
		arg_to_raw (&arg, resp, type_info);

		g_base_info_unref ((GIBaseInfo *) type_info);
	}

	PUTBACK;

	g_base_info_unref ((GIBaseInfo *) return_type);

	FREETMPS;
	LEAVE;

	/* FIXME: We can't just free everything here because ffi will use parts
	 * of this after we've returned.
	 *
	 * if (info->free_after_use) {
	 * 	release_callback (info);
	 * }
	 *
	 * Gjs uses a global list of callback infos instead and periodically
	 * frees unused ones.
	 */
}

static void
release_callback (gpointer data)
{
	GPerlI11nCallbackInfo *info = data;
	dwarn ("releasing callback info %p\n", info);

	if (info->cif)
		g_free (info->cif);

	if (info->closure)
		g_callable_info_free_closure (info->interface, info->closure);

	if (info->interface)
		g_base_info_unref ((GIBaseInfo*) info->interface);

	if (info->code)
		SvREFCNT_dec (info->code);

	if (info->data)
		SvREFCNT_dec (info->data);

	g_free (info);
}

/* ------------------------------------------------------------------------- */

static void
store_methods (HV *namespaced_functions, GIBaseInfo *info, GIInfoType info_type)
{
	const gchar *namespace;
	AV *av;
	gint i;

	namespace = g_base_info_get_name (info);
	av = newAV ();

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    {
		gint n_methods = g_object_info_get_n_methods (
		                   (GIObjectInfo *) info);
		for (i = 0; i < n_methods; i++) {
			GIFunctionInfo *function_info =
				g_object_info_get_method (
					(GIObjectInfo *) info, i);
			const gchar *function_name =
				g_base_info_get_name (
					(GIBaseInfo *) function_info);
			av_push (av, newSVpv (function_name, PL_na));
			g_base_info_unref ((GIBaseInfo *) function_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_INTERFACE:
	    {
		gint n_methods = g_interface_info_get_n_methods (
		                   (GIInterfaceInfo *) info);
		for (i = 0; i < n_methods; i++) {
			GIFunctionInfo *function_info =
				g_interface_info_get_method (
					(GIInterfaceInfo *) info, i);
			const gchar *function_name =
				g_base_info_get_name (
					(GIBaseInfo *) function_info);
			av_push (av, newSVpv (function_name, PL_na));
			g_base_info_unref ((GIBaseInfo *) function_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    {
		gint n_methods = g_struct_info_get_n_methods (
		                   (GIStructInfo *) info);
		for (i = 0; i < n_methods; i++) {
			GIFunctionInfo *function_info =
				g_struct_info_get_method (
					(GIStructInfo *) info, i);
			const gchar *function_name =
				g_base_info_get_name (
					(GIBaseInfo *) function_info);
			av_push (av, newSVpv (function_name, PL_na));
			g_base_info_unref ((GIBaseInfo *) function_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_UNION:
	    {
		/* FIXME */
		break;
	    }

	    default:
		croak ("store_methods: unsupported info type %d", info_type);
	}

	gperl_hv_take_sv (namespaced_functions, namespace, strlen (namespace),
	                  newRV_noinc ((SV *) av));
}

/* ------------------------------------------------------------------------- */

MODULE = Glib::Object::Introspection	PACKAGE = Glib::Object::Introspection

void
register_types (class, namespace, version, package)
	const gchar *namespace
	const gchar *version
	const gchar *package
    PREINIT:
	GIRepository *repository;
	GError *error = NULL;
	gint number, i;
	AV *global_functions;
	HV *namespaced_functions;
    PPCODE:
	repository = g_irepository_get_default ();
	g_irepository_require (repository, namespace, version, 0, &error);
	if (error) {
		gperl_croak_gerror (NULL, error);
	}

	global_functions = newAV ();
	namespaced_functions = newHV ();

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

		if (info_type == GI_INFO_TYPE_FUNCTION) {
			av_push (global_functions, newSVpv (name, PL_na));
		}

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

		type = g_registered_type_info_get_g_type (
			(GIRegisteredTypeInfo *) info);
		if (!type) {
			croak ("Could not find GType for type %s::%s",
			       namespace, name);
		}
		if (type == G_TYPE_NONE) {
			g_base_info_unref ((GIBaseInfo *) info);
			continue;
		}

		full_package = g_strconcat (package, "::", name, NULL);
		dwarn ("registering %s, %d => %s\n",
		       g_type_name (type), type,
		       full_package);

		if (info_type == GI_INFO_TYPE_OBJECT ||
		    info_type == GI_INFO_TYPE_INTERFACE ||
		    info_type == GI_INFO_TYPE_BOXED ||
		    info_type == GI_INFO_TYPE_STRUCT ||
		    info_type == GI_INFO_TYPE_UNION)
		{
			store_methods (namespaced_functions, info, info_type);
		}

		switch (info_type) {
		    case GI_INFO_TYPE_OBJECT:
		    case GI_INFO_TYPE_INTERFACE:
			gperl_register_object (type, full_package);
			break;

		    case GI_INFO_TYPE_BOXED:
		    case GI_INFO_TYPE_STRUCT:
		    case GI_INFO_TYPE_UNION:
			gperl_register_boxed (type, full_package, NULL);
			break;

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

	EXTEND (SP, 1);
	PUSHs (sv_2mortal (newRV_noinc ((SV *) namespaced_functions)));

void
invoke (class, basename, namespace, method, ...)
	const gchar *basename
	const gchar_ornull *namespace
	const gchar *method
PREINIT:
	int stack_offset = 4;
	GIRepository *repository;
	GIFunctionInfo *info;
	ffi_cif cif;
	ffi_type **arg_types = NULL;
	ffi_type *return_type_ffi = NULL;
	gpointer *args = NULL;
	gpointer func_pointer = NULL, instance = NULL;
	const gchar *symbol = NULL;
	int have_args;
	int n_args, n_invoke_args;
	int n_in_args;
	int n_out_args;
	int i, out_i;
	GITypeInfo ** out_arg_type = NULL;
	GITypeInfo * return_type_info = NULL;
	gboolean throws, is_constructor, is_method, has_return_value;
	GPerlI11nInvocationInfo invocation_info = {0,};
	GArgument return_value;
	GArgument * in_args = NULL;
	GArgument * out_args = NULL;
	GError * local_error = NULL;
	gpointer local_error_address = &local_error;
PPCODE:
	repository = g_irepository_get_default ();
	info = get_function_info (repository, basename, namespace, method);
	symbol = g_function_info_get_symbol (info);

	if (!g_typelib_symbol (g_base_info_get_typelib((GIBaseInfo *) info),
			       symbol, &func_pointer))
	{
		croak ("Could not locate symbol %s", symbol);
	}

	is_constructor =
		g_function_info_get_flags (info) & GI_FUNCTION_IS_CONSTRUCTOR;
	if (is_constructor) {
		stack_offset++;
	}

	have_args = items - stack_offset;

	n_invoke_args = n_args =
		g_callable_info_get_n_args ((GICallableInfo *) info);

	throws = g_function_info_get_flags (info) & GI_FUNCTION_THROWS;
	if (throws) {
		n_invoke_args++;
	}

	is_method =
		(g_function_info_get_flags (info) & GI_FUNCTION_IS_METHOD)
	    && !is_constructor;
	if (is_method) {
		n_invoke_args++;
	}

	dwarn ("invoke: %s -> n_args %d, n_invoke_args %d, have_args %d\n",
	       symbol, n_args, n_invoke_args, have_args);

	/* to allow us to make only one pass through the arg list, allocate
	 * enough space for all args in both the out and in lists.  we'll
	 * only use as much as we need.  since function argument lists are
	 * typically small, this shouldn't be a big problem. */
	if (n_invoke_args) {
		in_args = gperl_alloc_temp (sizeof (GArgument) * n_invoke_args);
		out_args = gperl_alloc_temp (sizeof (GArgument) * n_invoke_args);
		out_arg_type = gperl_alloc_temp (sizeof (GITypeInfo*) * n_invoke_args);

		arg_types = gperl_alloc_temp (sizeof (ffi_type *) * n_invoke_args);
		args = gperl_alloc_temp (sizeof (gpointer) * n_invoke_args);
	}

	n_in_args = n_out_args = 0;

	if (is_method) {
		instance = instance_sv_to_pointer (info, ST (0 + stack_offset));
		arg_types[0] = &ffi_type_pointer;
		args[0] = &instance;
		n_in_args++;
	}

	int method_offset = is_method ? 1 : 0;

	for (i = 0 ; i < n_args ; i++) {
		GIArgInfo * arg_info =
			g_callable_info_get_arg ((GICallableInfo *) info, i);
		/* In case of out and in-out args, arg_type is unref'ed after
		 * the function has been invoked */
		GITypeInfo * arg_type = g_arg_info_get_type (arg_info);
		gboolean may_be_null = g_arg_info_may_be_null (arg_info);

		/* FIXME: Is it right to just add method_offset here?  I'm
		 * confused about the relation of the numbers in
		 * g_callable_info_get_arg and g_arg_info_get_closure and
		 * g_arg_info_get_destroy. */
		invocation_info.current_pos = method_offset + i;

		dwarn ("  arg tag: %d (%s)\n",
		       g_type_info_get_tag (arg_type),
		       g_type_tag_to_string (g_type_info_get_tag (arg_type)));

		switch (g_arg_info_get_direction (arg_info)) {
		    case GI_DIRECTION_IN:
			sv_to_arg (ST (i + method_offset + stack_offset),
			           &in_args[n_in_args], arg_info, arg_type,
			           may_be_null, &invocation_info);
			arg_types[i + method_offset] =
				g_type_info_get_ffi_type (arg_type);
			args[i + method_offset] = &in_args[n_in_args];
			g_base_info_unref ((GIBaseInfo *) arg_type);
			n_in_args++;
			break;
		    case GI_DIRECTION_OUT:
			out_args[n_out_args].v_pointer =
				gperl_alloc_temp (sizeof (GArgument));
			out_arg_type[n_out_args] = arg_type;
			arg_types[i + method_offset] = &ffi_type_pointer;
			args[i + method_offset] = &out_args[n_out_args];
			n_out_args++;
			break;
		    case GI_DIRECTION_INOUT:
		    {
			GArgument * temp =
				gperl_alloc_temp (sizeof (GArgument));
			sv_to_arg (ST (i + method_offset + stack_offset),
			           temp, arg_info, arg_type, may_be_null,
			           &invocation_info);
			in_args[n_in_args].v_pointer =
				out_args[n_out_args].v_pointer =
					temp;
			out_arg_type[n_out_args] = arg_type;
			arg_types[i + method_offset] = &ffi_type_pointer;
			args[i + method_offset] = &in_args[n_in_args];
			n_in_args++;
			n_out_args++;
		    }
			break;
		}

		g_base_info_unref ((GIBaseInfo *) arg_info);
	}

	if (throws) {
		args[n_invoke_args - 1] = &local_error_address;
		arg_types[n_invoke_args - 1] = &ffi_type_pointer;
	}

	/* find the return value type */
	return_type_info =
		g_callable_info_get_return_type ((GICallableInfo *) info);
	return_type_ffi = g_type_info_get_ffi_type (return_type_info);

	/* prepare and call the function */
	if (FFI_OK != ffi_prep_cif (&cif, FFI_DEFAULT_ABI, n_invoke_args,
	                            return_type_ffi, arg_types))
	{
		g_base_info_unref ((GIBaseInfo *) return_type_info);
		croak ("Could not prepare a call interface for %s", symbol);
	}

	ffi_call (&cif, func_pointer, &return_value, args);

	/* free call-scoped callback infos */
	g_slist_foreach (invocation_info.free_after_call,
	                 (GFunc) release_callback, NULL);

	g_slist_free (invocation_info.callback_infos);
	g_slist_free (invocation_info.free_after_call);

	if (local_error) {
		gperl_croak_gerror (NULL, local_error);
	}

	/*
	 * place return value and output args on the stack
	 */
	has_return_value =
		GI_TYPE_TAG_VOID != g_type_info_get_tag (return_type_info);
	if (has_return_value) {
		GITransfer return_type_transfer =
			g_callable_info_get_caller_owns ((GICallableInfo *) info);
		SV *value = arg_to_sv (&return_value,
		                       return_type_info,
		                       return_type_transfer);
		if (value)
			XPUSHs (sv_2mortal (value));
	}

	g_base_info_unref ((GIBaseInfo *) return_type_info);

	/* out args */
	for (i = out_i = 0 ; i < n_args ; i++) {
		GIArgInfo * arg_info =
			g_callable_info_get_arg ((GICallableInfo *) info, i);

		switch (g_arg_info_get_direction (arg_info)) {
		    case GI_DIRECTION_OUT:
		    case GI_DIRECTION_INOUT:
		    {
			GITransfer transfer =
				g_arg_info_get_ownership_transfer (arg_info);
			SV *sv = arg_to_sv (out_args[out_i].v_pointer,
			                    out_arg_type[out_i], transfer);
			if (sv)
				XPUSHs (sv_2mortal (sv));
			g_base_info_unref ((GIBaseInfo*) out_arg_type[out_i]);
		    }
			out_i++;
			break;
		    default:
			break;
		}

		g_base_info_unref ((GIBaseInfo *) arg_info);
	}

	g_base_info_unref ((GIBaseInfo *) info);

	if (has_return_value)
		out_i++;

	dwarn ("  number of return values: %d\n", out_i);

	if (out_i == 0) {
		XSRETURN_EMPTY;
	} else if (out_i == 1) {
		XSRETURN (1);
	} else {
		PUTBACK;
		return;
	}
