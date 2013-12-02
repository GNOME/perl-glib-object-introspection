/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

static gpointer
instance_sv_to_pointer (GICallableInfo *info, SV *sv)
{
	// We do *not* own container.
	GIBaseInfo *container = g_base_info_get_container (info);
	GIInfoType info_type = g_base_info_get_type (container);
	gpointer pointer = NULL;

	/* FIXME: Much of this code is duplicated in sv_to_interface. */

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
		GType type = get_gtype ((GIRegisteredTypeInfo *) container);
		if (!type || type == G_TYPE_NONE) {
			dwarn ("    unboxed type\n");
			pointer = sv_to_struct (GI_TRANSFER_NOTHING,
			                        container,
			                        info_type,
			                        sv);
		} else {
			dwarn ("    boxed type: %s (%"G_GSIZE_FORMAT")\n",
			       g_type_name (type), type);
			pointer = gperl_get_boxed_check (sv, type);
		}
		dwarn ("    -> boxed pointer: %p\n", pointer);
		break;
	    }

	    default:
		ccroak ("instance_sv_to_pointer: Don't know how to handle info type %d", info_type);
	}

	return pointer;
}

/* This may call Perl code (via gperl_new_boxed, gperl_sv_from_value,
 * struct_to_sv), so it needs to be wrapped with PUTBACK/SPAGAIN by the
 * caller. */
static SV *
instance_pointer_to_sv (GICallableInfo *info, gpointer pointer)
{
	// We do *not* own container.
	GIBaseInfo *container = g_base_info_get_container (info);
	GIInfoType info_type = g_base_info_get_type (container);
	SV *sv = NULL;

	/* FIXME: Much of this code is duplicated in interface_to_sv. */

	dwarn ("  instance_pointer_to_sv: container name: %s, info type: %d\n",
	       g_base_info_get_name (container),
	       info_type);

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		sv = gperl_new_object (pointer, FALSE);
		dwarn ("    -> object SV: %p\n", sv);
		break;

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    case GI_INFO_TYPE_UNION:
	    {
		GType type = get_gtype ((GIRegisteredTypeInfo *) container);
		if (!type || type == G_TYPE_NONE) {
			dwarn ("    unboxed type\n");
			sv = struct_to_sv (container, info_type, pointer, FALSE);
		} else {
			dwarn ("    boxed type: %s (%"G_GSIZE_FORMAT")\n",
			       g_type_name (type), type);
			sv = gperl_new_boxed (pointer, type, FALSE);
		}
		dwarn ("    -> boxed pointer: %p\n", pointer);
		break;
	    }

	    default:
		ccroak ("instance_pointer_to_sv: Don't know how to handle info type %d", info_type);
	}

	return sv;
}

static void
sv_to_interface (GIArgInfo * arg_info,
                 GITypeInfo * type_info,
                 GITransfer transfer,
                 gboolean may_be_null,
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
		if (may_be_null && !gperl_sv_is_defined (sv)) {
			arg->v_pointer = NULL;
		} else {
			arg->v_pointer = gperl_get_object_check (sv, get_gtype (interface));
		}
		if (arg->v_pointer) {
			GObject *object = arg->v_pointer;
			if (transfer == GI_TRANSFER_NOTHING &&
			    object->ref_count == 1 &&
			    SvTEMP (sv) && SvREFCNT (SvRV (sv)) == 1)
			{
				cwarn ("*** Asked to hand out object without ownership transfer, "
				       "but object is about to be destroyed; "
				       "adding an additional reference for safety");
				transfer = GI_TRANSFER_EVERYTHING;
			}
			if (transfer >= GI_TRANSFER_CONTAINER) {
				g_object_ref (arg->v_pointer);
			}
		}
		break;

	    case GI_INFO_TYPE_UNION:
	    case GI_INFO_TYPE_STRUCT:
	    case GI_INFO_TYPE_BOXED:
	    {
		gboolean need_value_semantics =
			arg_info && g_arg_info_is_caller_allocates (arg_info)
			&& !g_type_info_is_pointer (type_info);
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (!type || type == G_TYPE_NONE) {
			const gchar *namespace, *name, *package;
			GType parent_type;
			dwarn ("    unboxed type\n");
			g_assert (!need_value_semantics);
			/* Find out whether this untyped struct is a member of
			 * a boxed union before using raw hash-to-struct
			 * conversion. */
			name = g_base_info_get_name (interface);
			namespace = g_base_info_get_namespace (interface);
			package = get_package_for_basename (namespace);
			parent_type = package ? find_union_member_gtype (package, name) : 0;
			if (parent_type && parent_type != G_TYPE_NONE) {
				arg->v_pointer = gperl_get_boxed_check (
				                   sv, parent_type);
				if (GI_TRANSFER_EVERYTHING == transfer)
					arg->v_pointer =
						g_boxed_copy (parent_type,
						              arg->v_pointer);
			} else {
				arg->v_pointer = sv_to_struct (transfer,
				                               interface,
				                               info_type,
				                               sv);
			}
		} else if (type == G_TYPE_CLOSURE) {
			/* FIXME: User cannot supply user data. */
			dwarn ("    closure type\n");
			g_assert (!need_value_semantics);
			arg->v_pointer = gperl_closure_new (sv, NULL, FALSE);
		} else if (type == G_TYPE_VALUE) {
			GValue *gvalue = SvGValueWrapper (sv);
			dwarn ("    value type\n");
			if (!gvalue)
				ccroak ("Cannot convert arbitrary SV to GValue");
			if (need_value_semantics) {
				g_value_init (arg->v_pointer, G_VALUE_TYPE (gvalue));
				g_value_copy (gvalue, arg->v_pointer);
			} else {
				if (GI_TRANSFER_EVERYTHING == transfer) {
					arg->v_pointer = g_new0 (GValue, 1);
					g_value_init (arg->v_pointer, G_VALUE_TYPE (gvalue));
					g_value_copy (gvalue, arg->v_pointer);
				} else {
					arg->v_pointer = gvalue;
				}
			}
		} else {
			dwarn ("    boxed type: %s, name=%s, caller-allocates=%d, is-pointer=%d\n",
			       g_type_name (type),
			       g_base_info_get_name (interface),
			       g_arg_info_is_caller_allocates (arg_info),
			       g_type_info_is_pointer (type_info));
			if (need_value_semantics) {
				if (may_be_null && !gperl_sv_is_defined (sv)) {
					/* Do nothing. */
				} else {
					gsize n_bytes = g_struct_info_get_size (interface);
					gpointer mem = gperl_get_boxed_check (sv, type);
					g_memmove (arg->v_pointer, mem, n_bytes);
				}
			} else {
				if (may_be_null && !gperl_sv_is_defined (sv)) {
					arg->v_pointer = NULL;
				} else {
					arg->v_pointer = gperl_get_boxed_check (sv, type);
					if (GI_TRANSFER_EVERYTHING == transfer)
						arg->v_pointer = g_boxed_copy (
							type, arg->v_pointer);
				}
			}
		}
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    {
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (G_TYPE_NONE == type) {
			ccroak ("Could not handle unknown enum type %s",
			        g_base_info_get_name (interface));
		}
		/* FIXME: Check storage type? */
		arg->v_long = gperl_convert_enum (type, sv);
		break;
	    }

	    case GI_INFO_TYPE_FLAGS:
	    {
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (G_TYPE_NONE == type) {
			ccroak ("Could not handle unknown flags type %s",
			        g_base_info_get_name (interface));
		}
		/* FIXME: Check storage type? */
		arg->v_long = gperl_convert_flags (type, sv);
		break;
	    }

	    case GI_INFO_TYPE_CALLBACK:
		arg->v_pointer = sv_to_callback (arg_info, type_info, sv,
		                                 invocation_info);
		break;

	    default:
		ccroak ("sv_to_interface: Could not handle info type %s (%d)",
		        g_info_type_to_string (info_type),
		        info_type);
	}

	g_base_info_unref ((GIBaseInfo *) interface);
}

/* This may call Perl code (via gperl_new_boxed, gperl_sv_from_value,
 * struct_to_sv), so it needs to be wrapped with PUTBACK/SPAGAIN by the
 * caller. */
static SV *
interface_to_sv (GITypeInfo* info, GIArgument *arg, gboolean own, GPerlI11nInvocationInfo *iinfo)
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
		/* FIXME: What about pass-by-value here? */
		GType type;
		type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (!type || type == G_TYPE_NONE) {
			dwarn ("    unboxed type\n");
			sv = struct_to_sv (interface, info_type, arg->v_pointer, own);
		} else if (type == G_TYPE_VALUE) {
			dwarn ("    value type\n");
			sv = gperl_sv_from_value (arg->v_pointer);
			if (own)
				g_boxed_free (type, arg->v_pointer);
		} else {
			dwarn ("    boxed type: %"G_GSIZE_FORMAT" (%s)\n",
			       type, g_type_name (type));
			sv = gperl_new_boxed (arg->v_pointer, type, own);
		}
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    {
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (G_TYPE_NONE == type) {
			ccroak ("Could not handle unknown enum type %s",
			        g_base_info_get_name (interface));
		}
		/* FIXME: Is it right to just use v_long here? */
		sv = gperl_convert_back_enum (type, arg->v_long);
		break;
	    }

	    case GI_INFO_TYPE_FLAGS:
	    {
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (G_TYPE_NONE == type) {
			ccroak ("Could not handle unknown flags type %s",
			        g_base_info_get_name (interface));
		}
		/* FIXME: Is it right to just use v_long here? */
		sv = gperl_convert_back_flags (type, arg->v_long);
		break;
	    }

	    case GI_INFO_TYPE_CALLBACK:
		sv = callback_to_sv (interface, arg->v_pointer, iinfo);
		break;

	    default:
		ccroak ("interface_to_sv: Don't know how to handle info type %s (%d)",
		        g_info_type_to_string (info_type),
		        info_type);
	}

	g_base_info_unref ((GIBaseInfo *) interface);

	return sv;
}
