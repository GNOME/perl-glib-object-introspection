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

#include <string.h>

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

/* Call Carp's croak() so that errors are reported at their location in the
 * user's program, not in Introspection.pm.  Adapted from
 * <http://www.perlmonks.org/?node_id=865159>. */
#define ccroak(...) call_carp_croak (form (__VA_ARGS__));
static void
call_carp_croak (const char *msg)
{
	dSP;

	ENTER;
	SAVETMPS;

	PUSHMARK (SP);
	XPUSHs (sv_2mortal (newSVpv(msg, PL_na)));
	PUTBACK;

	call_pv("Carp::croak", G_VOID | G_DISCARD);

	FREETMPS;
	LEAVE;
}

/* ------------------------------------------------------------------------- */

typedef struct {
	ffi_cif *cif;
	ffi_closure *closure;

	GICallableInfo *interface;

	SV *code;
	SV *data;

	guint data_pos;
	guint notify_pos;

	gboolean free_after_use;

	gpointer priv; /* perl context */
} GPerlI11nCallbackInfo;

typedef struct {
	gsize length;
	guint length_pos;
} GPerlI11nArrayInfo;

/* This stores information that one call to sv_to_arg needs to make available
 * to later calls of sv_to_arg. */
typedef struct {
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

	guint current_pos;
	guint method_offset;
	gint stack_offset;
	gint dynamic_stack_offset;

	GSList * callback_infos;
	GSList * free_after_call;

	GSList * array_infos;
} GPerlI11nInvocationInfo;

static GPerlI11nCallbackInfo* create_callback_closure (GITypeInfo *cb_type, SV *code);
static void attach_callback_data (GPerlI11nCallbackInfo *info, SV *data);

static void invoke_callback (ffi_cif* cif, gpointer resp, gpointer* args, gpointer userdata);
static void release_callback (gpointer data);

static SV * arg_to_sv (GIArgument * arg,
                       GITypeInfo * info,
                       GITransfer transfer,
                       GPerlI11nInvocationInfo * iinfo);
static SV * interface_to_sv (GITypeInfo* info,
                             GIArgument *arg,
                             gboolean own);

static void sv_to_arg (SV * sv,
                       GIArgument * arg,
                       GIArgInfo * arg_info,
                       GITypeInfo * type_info,
                       GITransfer transfer,
                       gboolean may_be_null,
                       GPerlI11nInvocationInfo * invocation_info);

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
		GIFunctionInfo *function_info = NULL;
		GIBaseInfo *namespace_info = g_irepository_find_by_name (
			repository, basename, namespace);
		if (!namespace_info)
			ccroak ("Can't find information for namespace %s",
			       namespace);

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
                    case GI_INFO_TYPE_UNION:
                        function_info = g_union_info_find_method (
                                (GIUnionInfo *) namespace_info,
                                method);
                        break;
		    default:
			ccroak ("Base info for namespace %s has incorrect type",
			       namespace);
		}

		if (!function_info)
			ccroak ("Can't find information for method "
			       "%s::%s", namespace, method);

		g_base_info_unref (namespace_info);

		return function_info;
	} else {
		GIBaseInfo *method_info = g_irepository_find_by_name (
			repository, basename, method);

		if (!method_info)
			ccroak ("Can't find information for method %s", method);

		switch (g_base_info_get_type (method_info)) {
		    case GI_INFO_TYPE_FUNCTION:
			return (GIFunctionInfo *) method_info;
		    default:
			ccroak ("Base info for method %s has incorrect type",
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
			/* Decrease the dynamic stack offset so that this
			 * destroy notify callback doesn't consume any Perl
			 * value from the stack. */
			invocation_info->dynamic_stack_offset--;
			return release_callback;
		}
	}

	callback_info = create_callback_closure (type_info, sv);
	callback_info->data_pos = g_arg_info_get_closure (arg_info);
	callback_info->notify_pos = g_arg_info_get_destroy (arg_info);
	callback_info->free_after_use = FALSE;

	dwarn ("      callback data at %d, destroy at %d\n",
	       callback_info->data_pos, callback_info->notify_pos);

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
		ccroak ("unhandled scope type %d encountered",
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
handle_void_arg (SV * sv,
                 GPerlI11nInvocationInfo * invocation_info)
{
	gpointer pointer = NULL;
	gboolean is_user_data = FALSE;
	GSList *l;
	for (l = invocation_info->callback_infos; l != NULL; l = l->next) {
		GPerlI11nCallbackInfo *callback_info = l->data;
		if (callback_info->data_pos == invocation_info->current_pos) {
			is_user_data = TRUE;
			dwarn ("    user data for callback %p\n",
			       callback_info);
			attach_callback_data (callback_info, sv);
			pointer = callback_info;
			break; /* out of the for loop */
		}
	}
	if (!is_user_data)
		ccroak ("encountered void pointer that is not callback user data");
	return pointer;
}

/* ------------------------------------------------------------------------- */

/* These three are basically copied from pygi's pygi-info.c. :-( */

static gsize
size_of_type_tag (GITypeTag type_tag)
{
	switch(type_tag) {
	    case GI_TYPE_TAG_BOOLEAN:
		return sizeof (gboolean);
	    case GI_TYPE_TAG_INT8:
	    case GI_TYPE_TAG_UINT8:
		return sizeof (gint8);
	    case GI_TYPE_TAG_INT16:
	    case GI_TYPE_TAG_UINT16:
		return sizeof (gint16);
	    case GI_TYPE_TAG_INT32:
	    case GI_TYPE_TAG_UINT32:
		return sizeof (gint32);
	    case GI_TYPE_TAG_INT64:
	    case GI_TYPE_TAG_UINT64:
		return sizeof (gint64);
	    case GI_TYPE_TAG_FLOAT:
		return sizeof (gfloat);
	    case GI_TYPE_TAG_DOUBLE:
		return sizeof (gdouble);
	    case GI_TYPE_TAG_GTYPE:
		return sizeof (GType);
            case GI_TYPE_TAG_UNICHAR:
                return sizeof (gunichar);

	    case GI_TYPE_TAG_VOID:
	    case GI_TYPE_TAG_UTF8:
	    case GI_TYPE_TAG_FILENAME:
	    case GI_TYPE_TAG_ARRAY:
	    case GI_TYPE_TAG_INTERFACE:
	    case GI_TYPE_TAG_GLIST:
	    case GI_TYPE_TAG_GSLIST:
	    case GI_TYPE_TAG_GHASH:
	    case GI_TYPE_TAG_ERROR:
                ccroak ("Unable to determine the size of '%s'",
                        g_type_tag_to_string (type_tag));
                break;
	}

	return 0;
}

static gsize
size_of_interface (GITypeInfo *type_info)
{
	gsize size = 0;

	GIBaseInfo *info;
	GIInfoType info_type;

	info = g_type_info_get_interface (type_info);
	info_type = g_base_info_get_type (info);

	switch (info_type) {
	    case GI_INFO_TYPE_STRUCT:
		if (g_type_info_is_pointer (type_info)) {
			size = sizeof (gpointer);
		} else {
			size = g_struct_info_get_size ((GIStructInfo *) info);
		}
		break;

	    case GI_INFO_TYPE_UNION:
		if (g_type_info_is_pointer (type_info)) {
			size = sizeof (gpointer);
		} else {
			size = g_union_info_get_size ((GIUnionInfo *) info);
		}
		break;

	    case GI_INFO_TYPE_ENUM:
	    case GI_INFO_TYPE_FLAGS:
		if (g_type_info_is_pointer (type_info)) {
			size = sizeof (gpointer);
		} else {
			GITypeTag type_tag;
			type_tag = g_enum_info_get_storage_type ((GIEnumInfo *) info);
			size = size_of_type_tag (type_tag);
		}
		break;

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
	    case GI_INFO_TYPE_CALLBACK:
		size = sizeof (gpointer);
		break;

	    default:
		g_assert_not_reached ();
		break;
	}

	g_base_info_unref (info);

	return size;
}

static gsize
size_of_type_info (GITypeInfo *type_info)
{
	GITypeTag type_tag;

	type_tag = g_type_info_get_tag (type_info);
	switch (type_tag) {
	    case GI_TYPE_TAG_BOOLEAN:
	    case GI_TYPE_TAG_INT8:
	    case GI_TYPE_TAG_UINT8:
	    case GI_TYPE_TAG_INT16:
	    case GI_TYPE_TAG_UINT16:
	    case GI_TYPE_TAG_INT32:
	    case GI_TYPE_TAG_UINT32:
	    case GI_TYPE_TAG_INT64:
	    case GI_TYPE_TAG_UINT64:
	    case GI_TYPE_TAG_FLOAT:
	    case GI_TYPE_TAG_DOUBLE:
	    case GI_TYPE_TAG_GTYPE:
            case GI_TYPE_TAG_UNICHAR:
		if (g_type_info_is_pointer (type_info)) {
			return sizeof (gpointer);
		} else {
			return size_of_type_tag (type_tag);
		}

	    case GI_TYPE_TAG_INTERFACE:
		return size_of_interface (type_info);

	    case GI_TYPE_TAG_ARRAY:
	    case GI_TYPE_TAG_VOID:
	    case GI_TYPE_TAG_UTF8:
	    case GI_TYPE_TAG_FILENAME:
	    case GI_TYPE_TAG_GLIST:
	    case GI_TYPE_TAG_GSLIST:
	    case GI_TYPE_TAG_GHASH:
	    case GI_TYPE_TAG_ERROR:
		return sizeof (gpointer);
	}

	return 0;
}

/* ------------------------------------------------------------------------- */

static SV *
struct_to_sv (GIBaseInfo* info,
              GIInfoType info_type,
              gpointer pointer,
              gboolean own)
{
	HV *hv;

	dwarn ("%s: pointer %p\n", G_STRFUNC, pointer);

	if (pointer == NULL) {
		return &PL_sv_undef;
	}

	hv = newHV ();

	switch (info_type) {
	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    {
		gint i, n_fields =
			g_struct_info_get_n_fields ((GIStructInfo *) info);
		for (i = 0; i < n_fields; i++) {
			GIFieldInfo *field_info;
			GITypeInfo *field_type;
			GIArgument value;
			field_info =
				g_struct_info_get_field ((GIStructInfo *) info, i);
			field_type = g_field_info_get_type (field_info);
			/* FIXME: Check GIFieldInfoFlags. */
			if (g_field_info_get_field (field_info, pointer, &value)) {
				/* FIXME: Is it right to use
				 * GI_TRANSFER_NOTHING here? */
				SV *sv;
				const gchar *name;
				sv = arg_to_sv (&value,
				                field_type,
				                GI_TRANSFER_NOTHING,
				                NULL);
				name = g_base_info_get_name (
				         (GIBaseInfo *) field_info);
				gperl_hv_take_sv (hv, name, strlen (name), sv);
			}
			g_base_info_unref ((GIBaseInfo *) field_type);
			g_base_info_unref ((GIBaseInfo *) field_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_UNION:
		ccroak ("%s: unions not handled yet", G_STRFUNC);

	    default:
		ccroak ("%s: unhandled info type %d", G_STRFUNC, info_type);
	}

	if (own) {
		/* FIXME: Is it correct to just call g_free here?  What if the
		 * thing was allocated via GSlice? */
		g_free (pointer);
	}

	return newRV_noinc ((SV *) hv);
}

static gpointer
sv_to_struct (GIArgInfo * arg_info,
              GIBaseInfo * info,
              GIInfoType info_type,
              SV * sv)
{
	HV *hv;
	gsize size = 0;
	GITransfer transfer, field_transfer;
	gpointer pointer = NULL;

	dwarn ("%s: sv %p\n", G_STRFUNC, sv);

	if (!gperl_sv_is_hash_ref (sv))
		ccroak ("need a hash ref to convert to struct of type %s",
		       g_base_info_get_name (info));
	hv = (HV *) SvRV (sv);

	switch (info_type) {
	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
		size = g_struct_info_get_size ((GIStructInfo *) info);
		break;
	    case GI_INFO_TYPE_UNION:
		size = g_union_info_get_size ((GIStructInfo *) info);
		break;
	    default:
		g_assert_not_reached ();
	}

	dwarn ("  size: %d\n", size);

	field_transfer = GI_TRANSFER_NOTHING;
	transfer = g_arg_info_get_ownership_transfer (arg_info);
	dwarn ("  transfer: %d\n", transfer);
	switch (transfer) {
	    case GI_TRANSFER_EVERYTHING:
		field_transfer = GI_TRANSFER_EVERYTHING;
	    case GI_TRANSFER_CONTAINER:
		/* FIXME: What if there's a special allocator for the record?
		 * Like GSlice? */
		pointer = g_malloc0 (size);
		break;

	    default:
		pointer = gperl_alloc_temp (size);
		break;
	}

	switch (info_type) {
	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    {
		gint i, n_fields =
			g_struct_info_get_n_fields ((GIStructInfo *) info);
		for (i = 0; i < n_fields; i++) {
			GIFieldInfo *field_info;
			const gchar *field_name;
			SV **svp;
			field_info = g_struct_info_get_field (
			               (GIStructInfo *) info, i);
			/* FIXME: Check GIFieldInfoFlags. */
			field_name = g_base_info_get_name (
			               (GIBaseInfo *) field_info);
			svp = hv_fetch (hv, field_name, strlen (field_name), 0);
			if (svp && gperl_sv_is_defined (*svp)) {
				GITypeInfo *field_type;
				GIArgument arg;
				field_type = g_field_info_get_type (field_info);
				/* FIXME: No GIArgInfo and no
				 * GPerlI11nInvocationInfo here.  What if the
				 * struct contains an object pointer, or a
				 * callback field?  And is it OK to always
				 * allow undef? */
				sv_to_arg (*svp, &arg, NULL, field_type,
				           field_transfer, TRUE, NULL);
				g_field_info_set_field (field_info, pointer,
				                        &arg);
				g_base_info_unref ((GIBaseInfo *) field_type);
			}
			g_base_info_unref ((GIBaseInfo *) field_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_UNION:
		ccroak ("%s: unions not handled yet", G_STRFUNC);

	    default:
		ccroak ("%s: unhandled info type %d", G_STRFUNC, info_type);
	}

	return pointer;
}

/* ------------------------------------------------------------------------- */

static SV *
array_to_sv (GITypeInfo *info,
             gpointer pointer,
             GITransfer transfer,
             GPerlI11nInvocationInfo *iinfo)
{
	GITypeInfo *param_info;
	gboolean is_zero_terminated;
	gsize item_size;
	GITransfer item_transfer;
	gssize length, i;
	AV *av;

	if (pointer == NULL) {
		return &PL_sv_undef;
	}

	is_zero_terminated = g_type_info_is_zero_terminated (info);
	param_info = g_type_info_get_param_type (info, 0);
	item_size = size_of_type_info (param_info);

	/* FIXME: What about an array containing arrays of strings, where the
	 * outer array is GI_TRANSFER_EVERYTHING but the inner arrays are
	 * GI_TRANSFER_CONTAINER? */
	item_transfer = transfer == GI_TRANSFER_EVERYTHING
		? GI_TRANSFER_EVERYTHING
		: GI_TRANSFER_NOTHING;

	if (is_zero_terminated) {
		length = g_strv_length (pointer);
	} else {
                length = g_type_info_get_array_fixed_size (info);
                if (length < 0) {
			guint length_pos = g_type_info_get_array_length (info);
			g_assert (iinfo != NULL);
			/* FIXME: Is it OK to always use v_size here? */
			length = iinfo->aux_args[length_pos].v_size;
                }
	}

	if (length < 0) {
		ccroak ("Could not determine the length of the array");
	}

	av = newAV ();

	dwarn ("    C array: pointer %p, length %d, item size %d, "
	       "param_info %p with type tag %d (%s)\n",
	       pointer,
	       length,
	       item_size,
	       param_info,
	       g_type_info_get_tag (param_info),
	       g_type_tag_to_string (g_type_info_get_tag (param_info)));

	for (i = 0; i < length; i++) {
		GIArgument *arg;
		SV *value;
		arg = pointer + i * item_size;
		value = arg_to_sv (arg, param_info, item_transfer, iinfo);
		if (value)
			av_push (av, value);
	}

	if (transfer >= GI_TRANSFER_CONTAINER)
		g_free (pointer);

	g_base_info_unref ((GIBaseInfo *) param_info);

	return newRV_noinc ((SV *) av);
}

static gpointer
sv_to_array (GIArgInfo *arg_info,
             GITypeInfo *type_info,
             SV *sv,
             GPerlI11nInvocationInfo *iinfo)
{
	AV *av;
	GITransfer transfer, item_transfer;
	GITypeInfo *param_info;
	gint i, length, length_pos;
	GPerlI11nArrayInfo *array_info = NULL;
        GArray *array;
        gboolean is_zero_terminated = FALSE;
        gsize item_size;

	dwarn ("%s: sv %p\n", G_STRFUNC, sv);

	/* Add an array info entry even before the undef check so that the
	 * corresponding length arg is set to zero later by
	 * handle_automatic_arg. */
	length_pos = g_type_info_get_array_length (type_info);
	if (length_pos >= 0) {
		array_info = g_new0 (GPerlI11nArrayInfo, 1);
		array_info->length_pos = length_pos;
		array_info->length = 0;
		iinfo->array_infos = g_slist_prepend (iinfo->array_infos, array_info);
	}

	if (sv == &PL_sv_undef)
		return NULL;

	if (!gperl_sv_is_array_ref (sv))
		ccroak ("need an array ref to convert to GArray");

	av = (AV *) SvRV (sv);

	transfer = g_arg_info_get_ownership_transfer (arg_info);
        item_transfer = transfer == GI_TRANSFER_CONTAINER
                      ? GI_TRANSFER_NOTHING
                      : transfer;

	param_info = g_type_info_get_param_type (type_info, 0);
	dwarn ("  GArray: param_info %p with type tag %d (%s) and transfer %d\n",
	       param_info,
	       g_type_info_get_tag (param_info),
	       g_type_tag_to_string (g_type_info_get_tag (param_info)),
	       transfer);

        is_zero_terminated = g_type_info_is_zero_terminated (type_info);
        item_size = size_of_type_info (param_info);
	length = av_len (av) + 1;
        array = g_array_sized_new (is_zero_terminated, FALSE, item_size, length);

	for (i = 0; i < length; i++) {
		SV **svp;
		svp = av_fetch (av, i, 0);
		if (svp && gperl_sv_is_defined (*svp)) {
			GIArgument arg;

			dwarn ("    converting SV %p\n", *svp);
			/* FIXME: Is it OK to always allow undef here? */
			sv_to_arg (*svp, &arg, NULL, param_info,
			           item_transfer, TRUE, NULL);

                        g_array_insert_val (array, i, arg);
		}
	}

	dwarn ("    -> array %p of size %d\n", array, array->len);

	if (length_pos >= 0) {
		array_info->length = length;
	}

	g_base_info_unref ((GIBaseInfo *) param_info);

	return g_array_free (array, FALSE);
}

/* ------------------------------------------------------------------------- */

static SV *
glist_to_sv (GITypeInfo* info,
             gpointer pointer,
             GITransfer transfer)
{
	GITypeInfo *param_info;
	GITransfer item_transfer;
	gboolean is_slist;
	GSList *i;
	AV *av;
	SV *value;

	if (pointer == NULL) {
		return &PL_sv_undef;
	}

	/* FIXME: What about an array containing arrays of strings, where the
	 * outer array is GI_TRANSFER_EVERYTHING but the inner arrays are
	 * GI_TRANSFER_CONTAINER? */
	item_transfer = transfer == GI_TRANSFER_EVERYTHING
		? GI_TRANSFER_EVERYTHING
		: GI_TRANSFER_NOTHING;

	param_info = g_type_info_get_param_type (info, 0);
	dwarn ("    G(S)List: pointer %p, param_info %p with type tag %d (%s)\n",
	       pointer,
	       param_info,
	       g_type_info_get_tag (param_info),
	       g_type_tag_to_string (g_type_info_get_tag (param_info)));

	is_slist = GI_TYPE_TAG_GSLIST == g_type_info_get_tag (info);

	av = newAV ();
	for (i = pointer; i; i = i->next) {
		GIArgument arg = {0,};
		dwarn ("      converting pointer %p\n", i->data);
		arg.v_pointer = i->data;
		value = arg_to_sv (&arg, param_info, item_transfer, NULL);
		if (value)
			av_push (av, value);
	}

	if (transfer >= GI_TRANSFER_CONTAINER) {
		if (is_slist)
			g_slist_free (pointer);
		else
			g_list_free (pointer);
	}

	g_base_info_unref ((GIBaseInfo *) param_info);

	return newRV_noinc ((SV *) av);
}

static gpointer
sv_to_glist (GIArgInfo * arg_info, GITypeInfo * type_info, SV * sv)
{
	AV *av;
	GITransfer transfer, item_transfer;
	gpointer list = NULL;
	GITypeInfo *param_info;
	gboolean is_slist;
	gint i, length;

	dwarn ("%s: sv %p\n", G_STRFUNC, sv);

	if (sv == &PL_sv_undef)
		return NULL;

	if (!gperl_sv_is_array_ref (sv))
		ccroak ("need an array ref to convert to GList");
	av = (AV *) SvRV (sv);

	item_transfer = GI_TRANSFER_NOTHING;
	transfer = g_arg_info_get_ownership_transfer (arg_info);
	switch (transfer) {
	    case GI_TRANSFER_EVERYTHING:
		item_transfer = GI_TRANSFER_EVERYTHING;
		break;
	    case GI_TRANSFER_CONTAINER:
		/* nothing special to do */
		break;
	    case GI_TRANSFER_NOTHING:
		/* FIXME: need to free list after call */
		break;
	}

	param_info = g_type_info_get_param_type (type_info, 0);
	dwarn ("  G(S)List: param_info %p with type tag %d (%s) and transfer %d\n",
	       param_info,
	       g_type_info_get_tag (param_info),
	       g_type_tag_to_string (g_type_info_get_tag (param_info)),
	       transfer);

	is_slist = GI_TYPE_TAG_GSLIST == g_type_info_get_tag (type_info);

	length = av_len (av) + 1;
	for (i = 0; i < length; i++) {
		SV **svp;
		svp = av_fetch (av, i, 0);
		if (svp && gperl_sv_is_defined (*svp)) {
			GIArgument arg;
			dwarn ("    converting SV %p\n", *svp);
			/* FIXME: Is it OK to always allow undef here? */
			sv_to_arg (*svp, &arg, NULL, param_info,
			           item_transfer, TRUE, NULL);
                        /* ENHANCEME: Could use g_[s]list_prepend and
                         * later _reverse for efficiency. */
			if (is_slist)
				list = g_slist_append (list, arg.v_pointer);
			else
				list = g_list_append (list, arg.v_pointer);
		}
	}

	dwarn ("    -> list %p of length %d\n", list, g_list_length (list));

	g_base_info_unref ((GIBaseInfo *) param_info);

	return list;
}

static SV *
ghash_to_sv (GITypeInfo *info,
             gpointer pointer,
             GITransfer transfer)
{
	GITypeInfo *key_param_info, *value_param_info;
#ifdef NOISY
        GITypeTag key_type_tag, value_type_tag;
#endif
        gpointer key_p, value_p;
	GITransfer item_transfer;
	GHashTableIter iter;
	HV *hv;

	if (pointer == NULL) {
		return &PL_sv_undef;
	}

	item_transfer = transfer == GI_TRANSFER_EVERYTHING
		      ? GI_TRANSFER_EVERYTHING
                      : GI_TRANSFER_NOTHING;

	key_param_info = g_type_info_get_param_type (info, 0);
        value_param_info = g_type_info_get_param_type (info, 1);

#ifdef NOISY
        key_type_tag = g_type_info_get_tag (key_param_info);
        value_type_tag = g_type_info_get_tag (value_param_info);
#endif

	dwarn ("    GHashTable: pointer %p\n"
               "      key type tag %d (%s)\n"
               "      value type tag %d (%s)\n",
	       pointer,
	       key_type_tag, g_type_tag_to_string (key_type_tag),
	       value_type_tag, g_type_tag_to_string (value_type_tag));

	hv = newHV ();

        g_hash_table_iter_init (&iter, pointer);
        while (g_hash_table_iter_next (&iter, &key_p, &value_p)) {
		GIArgument arg = { 0, };
                SV *key_sv, *value_sv;

		dwarn ("      converting key pointer %p\n", key_p);
		arg.v_pointer = key_p;
		key_sv = arg_to_sv (&arg, key_param_info, item_transfer, NULL);
		if (key_sv == NULL)
                        break;

                dwarn ("      converting value pointer %p\n", value_p);
                arg.v_pointer = value_p;
                value_sv = arg_to_sv (&arg, value_param_info, item_transfer, NULL);
                if (value_sv == NULL)
                        break;

                (void) hv_store_ent (hv, key_sv, value_sv, 0);
	}

	g_base_info_unref ((GIBaseInfo *) key_param_info);
        g_base_info_unref ((GIBaseInfo *) value_param_info);

	return newRV_noinc ((SV *) hv);
}

static gpointer
sv_to_ghash (GIArgInfo *arg_info,
             GITypeInfo *type_info,
             SV *sv)
{
	HV *hv;
        HE *he;
	GITransfer transfer, item_transfer;
	gpointer hash;
	GITypeInfo *key_param_info, *value_param_info;
        GITypeTag key_type_tag;
        GHashFunc hash_func;
        GEqualFunc equal_func;
        I32 n_keys;

	dwarn ("%s: sv %p\n", G_STRFUNC, sv);

	if (sv == &PL_sv_undef)
		return NULL;

	if (!gperl_sv_is_hash_ref (sv))
		ccroak ("need an hash ref to convert to GHashTable");

	hv = (HV *) SvRV (sv);

	item_transfer = GI_TRANSFER_NOTHING;
	transfer = g_arg_info_get_ownership_transfer (arg_info);
	switch (transfer) {
	    case GI_TRANSFER_EVERYTHING:
		item_transfer = GI_TRANSFER_EVERYTHING;
		break;
	    case GI_TRANSFER_CONTAINER:
		/* nothing special to do */
		break;
	    case GI_TRANSFER_NOTHING:
		/* FIXME: need to free hash after call */
		break;
	}

	key_param_info = g_type_info_get_param_type (type_info, 0);
        value_param_info = g_type_info_get_param_type (type_info, 1);

        key_type_tag = g_type_info_get_tag (key_param_info);

        switch (key_type_tag)
          {
          case GI_TYPE_TAG_FILENAME:
          case GI_TYPE_TAG_UTF8:
            hash_func = g_str_hash;
            equal_func = g_str_equal;
            break;

          default:
            hash_func = NULL;
            equal_func = NULL;
            break;
          }

	dwarn ("  GHashTable with transfer %d\n"
               "    key_param_info %p with type tag %d (%s)\n"
               "    value_param_info %p with type tag %d (%s)\n",
               transfer,
	       key_param_info,
	       g_type_info_get_tag (key_param_info),
	       g_type_tag_to_string (g_type_info_get_tag (key_param_info)),
	       value_param_info,
	       g_type_info_get_tag (value_param_info),
	       g_type_tag_to_string (g_type_info_get_tag (value_param_info)));

        hash = g_hash_table_new (hash_func, equal_func);

        n_keys = hv_iterinit (hv);
        if (n_keys == 0)
                goto out;

        while ((he = hv_iternext (hv)) != NULL) {
                SV *sv;
                GIArgument arg = { 0, };
                gpointer key_p, value_p;

                key_p = value_p = NULL;

                sv = hv_iterkeysv (he);
		if (sv && gperl_sv_is_defined (sv)) {
			dwarn ("    converting key SV %p\n", sv);
			/* FIXME: Is it OK to always allow undef here? */
			sv_to_arg (sv, &arg, NULL, key_param_info,
			           item_transfer, TRUE, NULL);
                        key_p = arg.v_pointer;
		}

                sv = hv_iterval (hv, he);
                if (sv && gperl_sv_is_defined (sv)) {
                        dwarn ("    converting value SV %p\n", sv);
                        sv_to_arg (sv, &arg, NULL, key_param_info,
                                   item_transfer, TRUE, NULL);
                        value_p = arg.v_pointer;
                }

                if (key_p != NULL && value_p != NULL)
                        g_hash_table_insert (hash, key_p, value_p);
	}

out:
	dwarn ("    -> hash %p of size %d\n", hash, g_hash_table_size (hash));

        g_base_info_unref ((GIBaseInfo *) key_param_info);
	g_base_info_unref ((GIBaseInfo *) value_param_info);

	return hash;
}

/* ------------------------------------------------------------------------- */

static void
sv_to_interface (GIArgInfo * arg_info,
                 GITypeInfo * type_info,
                 SV * sv,
                 GIArgument * arg,
                 GPerlI11nInvocationInfo * invocation_info)
{
	GIBaseInfo *interface;
	GIInfoType info_type;

	interface = g_type_info_get_interface (type_info);
	if (!interface)
		ccroak ("Could not convert sv %p to pointer", sv);
	info_type = g_base_info_get_type (interface);

	dwarn ("    interface %p (%s) of type %d\n",
	       interface, g_base_info_get_name (interface), info_type);

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		/* FIXME: Check transfer setting. */
		arg->v_pointer = gperl_get_object (sv);
		break;

	    case GI_INFO_TYPE_UNION:
	    case GI_INFO_TYPE_STRUCT:
	    case GI_INFO_TYPE_BOXED:
	    {
		/* FIXME: What about pass-by-value here? */
		GType type = g_registered_type_info_get_g_type (
		               (GIRegisteredTypeInfo *) interface);
		if (!type || type == G_TYPE_NONE) {
			dwarn ("    unboxed type\n");
			arg->v_pointer = sv_to_struct (arg_info,
			                               interface,
			                               info_type,
			                               sv);
		} else if (type == G_TYPE_CLOSURE) {
			/* FIXME: User cannot supply user data. */
			dwarn ("    closure type\n");
			arg->v_pointer = gperl_closure_new (sv, NULL, FALSE);
		} else if (type == G_TYPE_VALUE) {
			dwarn ("    value type\n");
			croak ("Cannot convert SV to GValue");
		} else {
			dwarn ("    boxed type: %s (%d)\n",
			       g_type_name (type), type);
			/* FIXME: Check transfer setting. */
			arg->v_pointer = gperl_get_boxed_check (sv, type);
		}
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		/* FIXME: Check storage type? */
		arg->v_long = gperl_convert_enum (type, sv);
		break;
	    }

	    case GI_INFO_TYPE_FLAGS:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		/* FIXME: Check storage type? */
		arg->v_long = gperl_convert_flags (type, sv);
		break;
	    }

	    case GI_INFO_TYPE_CALLBACK:
		arg->v_pointer = handle_callback_arg (arg_info, type_info, sv,
		                                      invocation_info);
		break;

	    default:
		ccroak ("sv_to_interface: Don't know how to handle info type %d", info_type);
	}

	g_base_info_unref ((GIBaseInfo *) interface);
}

static SV *
interface_to_sv (GITypeInfo* info, GIArgument *arg, gboolean own)
{
	GIBaseInfo *interface;
	GIInfoType info_type;
	SV *sv = NULL;

	dwarn ("  interface_to_sv: arg %p, info %p\n",
	       arg, info);

	interface = g_type_info_get_interface (info);
	if (!interface)
		ccroak ("Could not convert arg %p to SV", arg);
	info_type = g_base_info_get_type (interface);
	dwarn ("    info type: %d (%s)\n", info_type, g_info_type_to_string (info_type));

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		sv = gperl_new_object (arg->v_pointer, own);
		break;

	    case GI_INFO_TYPE_UNION:
	    case GI_INFO_TYPE_STRUCT:
	    case GI_INFO_TYPE_BOXED:
	    {
		GType type;
		gpointer pointer;
		type = g_registered_type_info_get_g_type (
		               (GIRegisteredTypeInfo *) interface);
		pointer = g_type_info_is_pointer (info)
			? arg->v_pointer
			: &arg->v_pointer;
		if (!type || type == G_TYPE_NONE) {
			dwarn ("    unboxed type\n");
			sv = struct_to_sv (interface, info_type, pointer, own);
		} else if (type == G_TYPE_VALUE) {
			dwarn ("    value type\n");
			sv = gperl_sv_from_value (pointer);
		} else {
			dwarn ("    boxed type: %d (%s)\n",
			       type, g_type_name (type));
			sv = gperl_new_boxed (pointer, type, own);
		}
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		/* FIXME: Is it right to just use v_long here? */
		sv = gperl_convert_back_enum (type, arg->v_long);
		break;
	    }

	    case GI_INFO_TYPE_FLAGS:
	    {
		GType type = g_registered_type_info_get_g_type ((GIRegisteredTypeInfo *) interface);
		/* FIXME: Is it right to just use v_long here? */
		sv = gperl_convert_back_flags (type, arg->v_long);
		break;
	    }

	    default:
		ccroak ("interface_to_sv: Don't know how to handle info type %d", info_type);
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
	gpointer pointer = NULL;

	dwarn ("  instance_sv_to_pointer: container name: %s, info type: %d\n",
	       g_base_info_get_name (container),
	       info_type);

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		pointer = gperl_get_object (sv);
		dwarn ("    -> object pointer: %p\n", pointer);
		break;

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
            case GI_INFO_TYPE_UNION:
	    {
		GType type = g_registered_type_info_get_g_type (
			       (GIRegisteredTypeInfo *) container);
		pointer = gperl_get_boxed_check (sv, type);
		dwarn ("    -> boxed pointer: %p\n", pointer);
		break;
	    }

	    default:
		ccroak ("instance_sv_to_pointer: Don't know how to handle info type %d", info_type);
	}

	return pointer;
}

/* ------------------------------------------------------------------------- */

/* transfer and may_be_null can be gotten from arg_info, but sv_to_arg is also
 * called from places which don't have access to a GIArgInfo. */
static void
sv_to_arg (SV * sv,
           GIArgument * arg,
           GIArgInfo * arg_info,
           GITypeInfo * type_info,
           GITransfer transfer,
           gboolean may_be_null,
           GPerlI11nInvocationInfo * invocation_info)
{
	GITypeTag tag = g_type_info_get_tag (type_info);

        memset (arg, 0, sizeof (GIArgument));

	if (!gperl_sv_is_defined (sv))
		/* Interfaces and void types need to be able to handle undef
		 * separately. */
		if (!may_be_null && tag != GI_TYPE_TAG_INTERFACE
		                 && tag != GI_TYPE_TAG_VOID)
			ccroak ("undefined value for mandatory argument '%s' encountered",
			       g_base_info_get_name ((GIBaseInfo *) arg_info));

	switch (tag) {
	    case GI_TYPE_TAG_VOID:
		arg->v_pointer = handle_void_arg (sv, invocation_info);
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

	    case GI_TYPE_TAG_UNICHAR:
		arg->v_uint32 = g_utf8_get_char (SvGChar (sv));
		break;

	    case GI_TYPE_TAG_GTYPE:
		/* GType == gsize */
		arg->v_size = gperl_type_from_package (SvPV_nolen (sv));
		if (!arg->v_size)
			arg->v_size = g_type_from_name (SvPV_nolen (sv));
		break;

	    case GI_TYPE_TAG_ARRAY:
                arg->v_pointer = sv_to_array (arg_info, type_info, sv, invocation_info);
		break;

	    case GI_TYPE_TAG_INTERFACE:
		dwarn ("    type %p -> interface\n", type_info);
		sv_to_interface (arg_info, type_info, sv, arg,
		                 invocation_info);
		break;

	    case GI_TYPE_TAG_GLIST:
	    case GI_TYPE_TAG_GSLIST:
		arg->v_pointer = sv_to_glist (arg_info, type_info, sv);
		break;

	    case GI_TYPE_TAG_GHASH:
                arg->v_pointer = sv_to_ghash (arg_info, type_info, sv);
		break;

	    case GI_TYPE_TAG_ERROR:
		ccroak ("FIXME - A GError as an in/inout arg?  Should never happen!");
		break;

	    case GI_TYPE_TAG_UTF8:
		arg->v_string = gperl_sv_is_defined (sv) ? SvGChar (sv) : NULL;
		if (transfer == GI_TRANSFER_EVERYTHING)
			arg->v_string = g_strdup (arg->v_string);
		break;

	    case GI_TYPE_TAG_FILENAME:
		/* FIXME: Is it correct to use gperl_filename_from_sv here? */
		arg->v_string = gperl_sv_is_defined (sv) ? gperl_filename_from_sv (sv) : NULL;
		if (transfer == GI_TRANSFER_EVERYTHING)
			arg->v_string = g_strdup (arg->v_string);
		break;

	    default:
		ccroak ("Unhandled info tag %d", tag);
	}
}

static SV *
arg_to_sv (GIArgument * arg,
           GITypeInfo * info,
           GITransfer transfer,
           GPerlI11nInvocationInfo *iinfo)
{
	GITypeTag tag = g_type_info_get_tag (info);
	gboolean own = transfer == GI_TRANSFER_EVERYTHING;

	dwarn ("  arg_to_sv: info %p with type tag %d (%s)\n",
	       info, tag, g_type_tag_to_string (tag));

	switch (tag) {
	    case GI_TYPE_TAG_VOID:
		dwarn ("    argument with no type information -> undef\n");
		return &PL_sv_undef;

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

	    case GI_TYPE_TAG_UNICHAR:
	    {
		SV *sv;
		gchar buffer[6];
		gint length = g_unichar_to_utf8 (arg->v_uint32, buffer);
		sv = newSVpv (buffer, length);
		SvUTF8_on (sv);
		return sv;
	    }

	    case GI_TYPE_TAG_GTYPE: {
		/* GType == gsize */
		const char *package = gperl_package_from_type (arg->v_size);
		if (!package)
			package = g_type_name (arg->v_size);
		return newSVpv (package, PL_na);
	    }

	    case GI_TYPE_TAG_ARRAY:
		return array_to_sv (info, arg->v_pointer, transfer, iinfo);

	    case GI_TYPE_TAG_INTERFACE:
		return interface_to_sv (info, arg, own);

	    case GI_TYPE_TAG_GLIST:
	    case GI_TYPE_TAG_GSLIST:
		return glist_to_sv (info, arg->v_pointer, transfer);

	    case GI_TYPE_TAG_GHASH:
                return ghash_to_sv (info, arg->v_pointer, transfer);

	    case GI_TYPE_TAG_ERROR:
		ccroak ("FIXME - GI_TYPE_TAG_ERROR");
		break;

	    case GI_TYPE_TAG_UTF8:
	    {
		SV *sv = newSVGChar (arg->v_string);
		if (own)
			g_free (arg->v_string);
		return sv;
	    }

	    case GI_TYPE_TAG_FILENAME:
	    {
		/* FIXME: Is it correct to use gperl_sv_from_filename here? */
		SV *sv = gperl_sv_from_filename (arg->v_string);
		if (own)
			g_free (arg->v_string);
		return sv;
	    }

	    default:
		ccroak ("Unhandled info tag %d", tag);
	}

	return NULL;
}

/* ------------------------------------------------------------------------- */

static void
handle_automatic_arg (guint pos,
                      GIArgument * arg,
                      GPerlI11nInvocationInfo * invocation_info)
{
	GSList *l;

	/* array length */
	for (l = invocation_info->array_infos; l != NULL; l = l->next) {
		GPerlI11nArrayInfo *ainfo = l->data;
		if (pos == ainfo->length_pos) {
			dwarn ("  setting automatic arg %d (array length) to %d\n",
			       pos, ainfo->length);
			/* FIXME: Is it OK to always use v_size here? */
			arg->v_size = ainfo->length;
			return;
		}
	}

	/* callback destroy notify */
	for (l = invocation_info->callback_infos; l != NULL; l = l->next) {
		GPerlI11nCallbackInfo *cinfo = l->data;
		if (pos == cinfo->notify_pos) {
			dwarn ("  setting automatic arg %d (destroy notify for calllback %p)\n",
			       pos, cinfo);
			arg->v_pointer = release_callback;
			return;
		}
	}

	ccroak ("Could not handle automatic arg %d", pos);
}

/* ------------------------------------------------------------------------- */

#define CAST_RAW(raw, type) (*((type *) raw))

static void
raw_to_arg (gpointer raw, GIArgument *arg, GITypeInfo *info)
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

	    case GI_TYPE_TAG_ARRAY:
	    case GI_TYPE_TAG_INTERFACE:
	    case GI_TYPE_TAG_GLIST:
	    case GI_TYPE_TAG_GSLIST:
	    case GI_TYPE_TAG_GHASH:
	    case GI_TYPE_TAG_ERROR:
		arg->v_pointer = * (gpointer *) raw;
		break;

	    case GI_TYPE_TAG_UTF8:
	    case GI_TYPE_TAG_FILENAME:
		arg->v_string = * (gchar **) raw;
		break;

	    default:
		ccroak ("Unhandled info tag %d", tag);
	}
}

static void
arg_to_raw (GIArgument *arg, gpointer raw, GITypeInfo *info)
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

	    case GI_TYPE_TAG_ARRAY:
	    case GI_TYPE_TAG_INTERFACE:
	    case GI_TYPE_TAG_GLIST:
	    case GI_TYPE_TAG_GSLIST:
	    case GI_TYPE_TAG_GHASH:
	    case GI_TYPE_TAG_ERROR:
		* (gpointer *) raw = arg->v_pointer;
		break;

	    case GI_TYPE_TAG_UTF8:
	    case GI_TYPE_TAG_FILENAME:
		* (gchar **) raw = arg->v_string;
		break;

	    default:
		ccroak ("Unhandled info tag %d", tag);
	}
}

/* ------------------------------------------------------------------------- */

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
	/* FIXME: This should most likely use SvREFCNT_inc instead of
	 * newSVsv. */
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

	PERL_UNUSED_VAR (cif);

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

		/* the closure argument, which we handle separately, is marked
		 * by having get_closure == i */
		if (g_arg_info_get_closure (arg_info) == i) {
			g_base_info_unref ((GIBaseInfo *) arg_info);
			g_base_info_unref ((GIBaseInfo *) arg_type);
			continue;
		}

		dwarn ("arg info: %p\n"
		       "  direction: %d\n"
		       "  is return value: %d\n"
		       "  is optional: %d\n"
		       "  may be null: %d\n"
		       "  transfer: %d\n",
		       arg_info,
		       g_arg_info_get_direction (arg_info),
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
			GIArgument arg;
			raw_to_arg (args[i], &arg, arg_type);
			XPUSHs (sv_2mortal (arg_to_sv (&arg, arg_type, transfer, NULL)));
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
		XPUSHs (sv_2mortal (SvREFCNT_inc (info->data)));

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
			ccroak ("callback returned %d values "
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

			if (direction == GI_DIRECTION_INOUT ||
			    direction == GI_DIRECTION_OUT)
			{
				GIArgument tmp_arg;
				GITransfer transfer = g_arg_info_get_ownership_transfer (arg_info);
				gboolean may_be_null = g_arg_info_may_be_null (arg_info);
				sv_to_arg (returned_values[out_index], &tmp_arg,
				           arg_info, arg_type,
				           transfer, may_be_null, NULL);
				arg_to_raw (&tmp_arg, args[i], arg_type);
				out_index++;
			}
		}

		g_free (returned_values);
	}

	/* store return value in resp, if any */
	if (have_return_type) {
		GIArgument arg;
		GITypeInfo *type_info;
		GITransfer transfer;
		gboolean may_be_null;

		type_info = g_callable_info_get_return_type (cb_interface);
		transfer = g_callable_info_get_caller_owns (cb_interface);
		may_be_null = g_callable_info_may_return_null (cb_interface);

		dwarn ("ret type: %p\n"
		       "  is pointer: %d\n"
		       "  tag: %d\n",
		       type_info,
		       g_type_info_is_pointer (type_info),
		       g_type_info_get_tag (type_info));

		/* FIXME: Does this leak the sv? */
		sv_to_arg (newSVsv (POPs), &arg, NULL, type_info,
		           transfer, may_be_null, NULL);
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
                gint n_methods = g_union_info_get_n_methods ((GIUnionInfo *) info);
                for (i = 0; i < n_methods; i++) {
                        GIFunctionInfo *function_info;
                        const gchar *function_name;

                        function_info = g_union_info_get_method ((GIUnionInfo *) info, i);
                        function_name = g_base_info_get_name ((GIBaseInfo *) function_info);

                        av_push (av, newSVpv (function_name, PL_na));
                        g_base_info_unref ((GIBaseInfo *) function_info);
                }
                break;
	    }

	    default:
		ccroak ("store_methods: unsupported info type %d", info_type);
	}

	gperl_hv_take_sv (namespaced_functions, namespace, strlen (namespace),
	                  newRV_noinc ((SV *) av));
}

/* ------------------------------------------------------------------------- */

static void
prepare_invocation_info (GPerlI11nInvocationInfo *iinfo,
                         GIFunctionInfo *info,
                         IV items,
                         UV internal_stack_offset)
{
	guint i;

	iinfo->stack_offset = internal_stack_offset;

	iinfo->is_constructor =
		g_function_info_get_flags (info) & GI_FUNCTION_IS_CONSTRUCTOR;
	if (iinfo->is_constructor) {
		iinfo->stack_offset++;
	}

	iinfo->n_given_args = items - iinfo->stack_offset;

	iinfo->n_invoke_args = iinfo->n_args =
		g_callable_info_get_n_args ((GICallableInfo *) info);

	iinfo->throws = g_function_info_get_flags (info) & GI_FUNCTION_THROWS;
	if (iinfo->throws) {
		iinfo->n_invoke_args++;
	}

	iinfo->is_method =
		(g_function_info_get_flags (info) & GI_FUNCTION_IS_METHOD)
	    && !iinfo->is_constructor;
	if (iinfo->is_method) {
		iinfo->n_invoke_args++;
	}

	dwarn ("invoke: %s\n"
	       "  n_args: %d, n_invoke_args: %d, n_given_args: %d\n"
	       "  is_constructor: %d, is_method: %d\n",
	       g_function_info_get_symbol (info),
	       iinfo->n_args, iinfo->n_invoke_args, iinfo->n_given_args,
	       iinfo->is_constructor, iinfo->is_method);

	iinfo->return_type_info =
		g_callable_info_get_return_type ((GICallableInfo *) info);
	iinfo->has_return_value =
		GI_TYPE_TAG_VOID != g_type_info_get_tag (iinfo->return_type_info);
	iinfo->return_type_ffi = g_type_info_get_ffi_type (iinfo->return_type_info);

	/* allocate enough space for all args in both the out and in lists.
	 * we'll only use as much as we need.  since function argument lists
	 * are typically small, this shouldn't be a big problem. */
	if (iinfo->n_invoke_args) {
		iinfo->in_args = gperl_alloc_temp (sizeof (GIArgument) * iinfo->n_invoke_args);
		iinfo->out_args = gperl_alloc_temp (sizeof (GIArgument) * iinfo->n_invoke_args);
		iinfo->out_arg_infos = gperl_alloc_temp (sizeof (GITypeInfo*) * iinfo->n_invoke_args);
		iinfo->arg_types = gperl_alloc_temp (sizeof (ffi_type *) * iinfo->n_invoke_args);
		iinfo->args = gperl_alloc_temp (sizeof (gpointer) * iinfo->n_invoke_args);
		iinfo->aux_args = gperl_alloc_temp (sizeof (GIArgument) * iinfo->n_invoke_args);
		iinfo->is_automatic_arg = gperl_alloc_temp (sizeof (gboolean) * iinfo->n_invoke_args);
	}

	iinfo->method_offset = iinfo->is_method ? 1 : 0;
	iinfo->dynamic_stack_offset = 0;

	/* Make a first pass to mark args that are filled in automatically, and
	 * thus have no counterpart on the Perl side. */
	for (i = 0 ; i < iinfo->n_args ; i++) {
		GIArgInfo * arg_info =
			g_callable_info_get_arg ((GICallableInfo *) info, i);
		GITypeInfo * arg_type = g_arg_info_get_type (arg_info);
		GITypeTag arg_tag = g_type_info_get_tag (arg_type);

		if (arg_tag == GI_TYPE_TAG_ARRAY) {
			gint pos = g_type_info_get_array_length (arg_type);
			if (pos >= 0) {
				dwarn ("  pos %d is automatic (array length)\n", pos);
				iinfo->is_automatic_arg[pos] = TRUE;
			}
		}

		else if (arg_tag == GI_TYPE_TAG_INTERFACE) {
			GIBaseInfo * interface = g_type_info_get_interface (arg_type);
			GIInfoType info_type = g_base_info_get_type (interface);
			if (info_type == GI_INFO_TYPE_CALLBACK) {
				gint pos = g_arg_info_get_destroy (arg_info);
				if (pos >= 0) {
					dwarn ("  pos %d is automatic (callback destroy notify)\n", pos);
					iinfo->is_automatic_arg[pos] = TRUE;
				}
			}
			g_base_info_unref ((GIBaseInfo *) interface);
		}

		g_base_info_unref ((GIBaseInfo *) arg_type);
		g_base_info_unref ((GIBaseInfo *) arg_info);
	}

	/* If the return value is an array which comes with an outbound length
	 * arg, then mark that length arg as automatic, too. */
	if (g_type_info_get_tag (iinfo->return_type_info) == GI_TYPE_TAG_ARRAY) {
		gint pos = g_type_info_get_array_length (iinfo->return_type_info);
		if (pos >= 0) {
			GIArgInfo * arg_info =
				g_callable_info_get_arg ((GICallableInfo *) info, pos);
			if (GI_DIRECTION_OUT == g_arg_info_get_direction (arg_info)) {
				dwarn ("  pos %d is automatic (array length)\n", pos);
				iinfo->is_automatic_arg[pos] = TRUE;
			}
		}
	}
}

static void
clear_invocation_info (GPerlI11nInvocationInfo *iinfo)
{
	g_slist_free (iinfo->free_after_call);

	/* The actual callback infos might be needed later, so we cannot free
	 * them here. */
	g_slist_free (iinfo->callback_infos);

	g_slist_foreach (iinfo->array_infos, (GFunc) g_free, NULL);
	g_slist_free (iinfo->array_infos);

	g_base_info_unref ((GIBaseInfo *) iinfo->return_type_info);
}

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
    PPCODE:
	repository = g_irepository_get_default ();

	constants = newAV ();
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

		if (info_type == GI_INFO_TYPE_CONSTANT) {
			av_push (constants, newSVpv (name, PL_na));
		}

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
			ccroak ("Could not find GType for type %s::%s",
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
	PUSHs (sv_2mortal (newRV_noinc ((SV *) constants)));

void
_fetch_constant (class, basename, constant)
	const gchar *basename
	const gchar *constant
    PREINIT:
	GIRepository *repository;
	GIConstantInfo *info;
	GITypeInfo *type_info;
	GIArgument value = {0,};
    PPCODE:
	repository = g_irepository_get_default ();
	info = g_irepository_find_by_name (repository, basename, constant);
	if (!GI_IS_CONSTANT_INFO (info))
		ccroak ("not a constant");
	type_info = g_constant_info_get_type (info);
	/* FIXME: What am I suppossed to do with the return value? */
	g_constant_info_get_value (info, &value);
	EXTEND (sp, 1);
	PUSHs (sv_2mortal (arg_to_sv (&value, type_info, GI_TRANSFER_NOTHING, NULL)));
	g_base_info_unref ((GIBaseInfo *) type_info);
	g_base_info_unref ((GIBaseInfo *) info);

void
_invoke (class, basename, namespace, method, ...)
	const gchar *basename
	const gchar_ornull *namespace
	const gchar *method
    PREINIT:
	UV internal_stack_offset = 4;
	GIRepository *repository;
	GIFunctionInfo *info;
	ffi_cif cif;
	gpointer func_pointer = NULL, instance = NULL;
	const gchar *symbol = NULL;
	guint i;
	GPerlI11nInvocationInfo iinfo = {0,};
	guint n_return_values;
	GIArgument return_value;
	GError * local_error = NULL;
	gpointer local_error_address = &local_error;
    PPCODE:
	repository = g_irepository_get_default ();
	info = get_function_info (repository, basename, namespace, method);
	symbol = g_function_info_get_symbol (info);

	if (!g_typelib_symbol (g_base_info_get_typelib((GIBaseInfo *) info),
			       symbol, &func_pointer))
	{
		ccroak ("Could not locate symbol %s", symbol);
	}

	prepare_invocation_info (&iinfo, info, items, internal_stack_offset);

	if (iinfo.is_method) {
		instance = instance_sv_to_pointer (info, ST (0 + iinfo.stack_offset));
		iinfo.arg_types[0] = &ffi_type_pointer;
		iinfo.args[0] = &instance;
	}

	for (i = 0 ; i < iinfo.n_args ; i++) {
		GIArgInfo * arg_info =
			g_callable_info_get_arg ((GICallableInfo *) info, i);
		/* In case of out and in-out args, arg_type is unref'ed after
		 * the function has been invoked */
		GITypeInfo * arg_type = g_arg_info_get_type (arg_info);
		GITransfer transfer = g_arg_info_get_ownership_transfer (arg_info);
		gboolean may_be_null = g_arg_info_may_be_null (arg_info);
		guint perl_stack_pos = i
                                     + iinfo.method_offset
                                     + iinfo.stack_offset
                                     + iinfo.dynamic_stack_offset;

		/* FIXME: Is this right?  I'm confused about the relation of
		 * the numbers in g_callable_info_get_arg and
		 * g_arg_info_get_closure and g_arg_info_get_destroy.  We used
		 * to add method_offset, but that stopped being correct at some
		 * point. */
		iinfo.current_pos = i; /* + method_offset; */

		dwarn ("  arg %d, tag: %d (%s), is_automatic: %d\n",
		       i,
		       g_type_info_get_tag (arg_type),
		       g_type_tag_to_string (g_type_info_get_tag (arg_type)),
		       iinfo.is_automatic_arg[i]);

		/* FIXME: Check that i+method_offset+stack_offset<items before
		 * calling ST, and generate a usage message otherwise. */
		switch (g_arg_info_get_direction (arg_info)) {
		    case GI_DIRECTION_IN:
			if (iinfo.is_automatic_arg[i]) {
				iinfo.dynamic_stack_offset--;
			} else {
				sv_to_arg (ST (perl_stack_pos),
				           &iinfo.in_args[i], arg_info, arg_type,
				           transfer, may_be_null, &iinfo);
			}
			iinfo.arg_types[i + iinfo.method_offset] =
				g_type_info_get_ffi_type (arg_type);
			iinfo.args[i + iinfo.method_offset] = &iinfo.in_args[i];
			g_base_info_unref ((GIBaseInfo *) arg_type);
			break;

		    case GI_DIRECTION_OUT:
			iinfo.out_args[i].v_pointer = &iinfo.aux_args[i];
			iinfo.out_arg_infos[i] = arg_type;
			iinfo.arg_types[i + iinfo.method_offset] = &ffi_type_pointer;
			iinfo.args[i + iinfo.method_offset] = &iinfo.out_args[i];
			/* Adjust the dynamic stack offset so that this out
			 * argument doesn't inadvertedly eat up an in argument. */
			iinfo.dynamic_stack_offset--;
			break;

		    case GI_DIRECTION_INOUT:
			iinfo.in_args[i].v_pointer =
				iinfo.out_args[i].v_pointer =
					&iinfo.aux_args[i];
			if (iinfo.is_automatic_arg[i]) {
				iinfo.dynamic_stack_offset--;
			} else {
				/* We pass iinfo.in_args[i].v_pointer here,
				 * not &iinfo.in_args[i], so that the value
				 * pointed to is filled from the SV. */
				sv_to_arg (ST (perl_stack_pos),
				           iinfo.in_args[i].v_pointer, arg_info, arg_type,
				           transfer, may_be_null, &iinfo);
			}
			iinfo.out_arg_infos[i] = arg_type;
			iinfo.arg_types[i + iinfo.method_offset] = &ffi_type_pointer;
			iinfo.args[i + iinfo.method_offset] = &iinfo.in_args[i];
			break;
		}

		g_base_info_unref ((GIBaseInfo *) arg_info);
	}

	/* do another pass to handle automatic args */
	for (i = 0 ; i < iinfo.n_args ; i++) {
		GIArgInfo * arg_info;
		if (!iinfo.is_automatic_arg[i])
			continue;
		arg_info = g_callable_info_get_arg ((GICallableInfo *) info, i);
		switch (g_arg_info_get_direction (arg_info)) {
		    case GI_DIRECTION_IN:
			handle_automatic_arg (i, &iinfo.in_args[i], &iinfo);
			break;
		    case GI_DIRECTION_INOUT:
			handle_automatic_arg (i, &iinfo.aux_args[i], &iinfo);
			break;
		    case GI_DIRECTION_OUT:
			/* handled later */
			break;
		}
	}

	if (iinfo.throws) {
		iinfo.args[iinfo.n_invoke_args - 1] = &local_error_address;
		iinfo.arg_types[iinfo.n_invoke_args - 1] = &ffi_type_pointer;
	}

	/* prepare and call the function */
	if (FFI_OK != ffi_prep_cif (&cif, FFI_DEFAULT_ABI, iinfo.n_invoke_args,
	                            iinfo.return_type_ffi, iinfo.arg_types))
	{
		clear_invocation_info (&iinfo);
		ccroak ("Could not prepare a call interface for %s", symbol);
	}

	ffi_call (&cif, func_pointer, &return_value, iinfo.args);

	/* free call-scoped callback infos */
	g_slist_foreach (iinfo.free_after_call,
	                 (GFunc) release_callback, NULL);

	if (local_error) {
		gperl_croak_gerror (NULL, local_error);
	}

	/*
	 * handle return values
	 */
	n_return_values = 0;

	/* place return value and output args on the stack */
	if (iinfo.has_return_value) {
		GITransfer return_type_transfer =
			g_callable_info_get_caller_owns ((GICallableInfo *) info);
		SV *value = arg_to_sv (&return_value,
		                       iinfo.return_type_info,
		                       return_type_transfer,
		                       &iinfo);
		if (value) {
			XPUSHs (sv_2mortal (value));
			n_return_values++;
		}
	}

	/* out args */
	for (i = 0 ; i < iinfo.n_args ; i++) {
		GIArgInfo * arg_info;
		if (iinfo.is_automatic_arg[i])
			continue;
		arg_info = g_callable_info_get_arg ((GICallableInfo *) info, i);
		switch (g_arg_info_get_direction (arg_info)) {
		    case GI_DIRECTION_OUT:
		    case GI_DIRECTION_INOUT:
		    {
			GITransfer transfer =
				g_arg_info_get_ownership_transfer (arg_info);
			SV *sv = arg_to_sv (iinfo.out_args[i].v_pointer,
			                    iinfo.out_arg_infos[i],
			                    transfer,
			                    &iinfo);
			if (sv) {
				XPUSHs (sv_2mortal (sv));
				n_return_values++;
			}
			g_base_info_unref ((GIBaseInfo*) iinfo.out_arg_infos[i]);
			break;
		    }

		    default:
			break;
		}

		g_base_info_unref ((GIBaseInfo *) arg_info);
	}

	clear_invocation_info (&iinfo);
	g_base_info_unref ((GIBaseInfo *) info);

	dwarn ("  number of return values: %d\n", n_return_values);

	if (n_return_values == 0) {
		XSRETURN_EMPTY;
	} else if (n_return_values == 1) {
		XSRETURN (1);
	} else {
		PUTBACK;
		return;
	}
