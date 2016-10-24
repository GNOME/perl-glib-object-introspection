/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

void _store_enum (GIEnumInfo * info, gint value, GIArgument * arg);
gint _retrieve_enum (GIEnumInfo * info, GIArgument * arg);

static gpointer
instance_sv_to_class_struct_pointer (SV *sv, GPerlI11nInvocationInfo *iinfo)
{
	gpointer pointer = NULL;
	GType class_type = 0;
	dwarn ("  -> gtype struct?\n");
	if (gperl_sv_is_ref (sv)) { /* instance? */
		const char *package = sv_reftype (SvRV (sv), TRUE);
		class_type = gperl_type_from_package (package);
	} else { /* package? */
		class_type = gperl_type_from_package (SvPV_nolen (sv));
	}
	dwarn ("     class_type = %s (%lu), is_classed = %d\n",
	       g_type_name (class_type), class_type, G_TYPE_IS_CLASSED (class_type));
	if (G_TYPE_IS_CLASSED (class_type)) {
		pointer = g_type_class_peek (class_type);
		if (!pointer) {
			/* If peek() produced NULL, the class has not been
			 * instantiated yet and needs to be created. */
			pointer = g_type_class_ref (class_type);
			free_after_call (iinfo, (GFunc) g_type_class_unref, pointer);
		}
		dwarn ("     type class = %p\n", pointer);
	}
	return pointer;
}

static gpointer
instance_sv_to_pointer (GICallableInfo *info, SV *sv, GPerlI11nInvocationInfo *iinfo)
{
	// We do *not* own container.
	GIBaseInfo *container = g_base_info_get_container (info);
	GIInfoType info_type = g_base_info_get_type (container);
	gpointer pointer = NULL;

	/* FIXME: Much of this code is duplicated in sv_to_interface. */

	dwarn ("container name = %s, info type = %d (%s)\n",
	       g_base_info_get_name (container),
	       info_type, g_info_type_to_string (info_type));

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		pointer = gperl_get_object (sv);
		dwarn ("  -> object pointer: %p\n", pointer);
		break;

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
            case GI_INFO_TYPE_UNION:
	    {
		GType type = get_gtype ((GIRegisteredTypeInfo *) container);
		if (!type || type == G_TYPE_NONE) {
			if (g_struct_info_is_gtype_struct (container)) {
				pointer = instance_sv_to_class_struct_pointer (sv, iinfo);
			}
			if (!pointer) {
				dwarn ("  -> untyped record\n");
				pointer = sv_to_struct (GI_TRANSFER_NOTHING,
				                        container,
				                        info_type,
				                        sv);
			}
		} else {
			dwarn ("  -> boxed: type=%s (%"G_GSIZE_FORMAT")\n",
			       g_type_name (type), type);
			pointer = gperl_get_boxed_check (sv, type);
		}
		dwarn ("  -> record pointer: %p\n", pointer);
		break;
	    }

	    default:
		ccroak ("Don't know how to handle info type %d for instance SV", info_type);
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

	dwarn ("container name = %s, info type = %d (%s)\n",
	       g_base_info_get_name (container),
	       info_type, g_info_type_to_string (info_type));

	switch (info_type) {
	    case GI_INFO_TYPE_OBJECT:
	    case GI_INFO_TYPE_INTERFACE:
		sv = gperl_new_object (pointer, FALSE);
		dwarn ("  -> object SV: %p\n", sv);
		break;

	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    case GI_INFO_TYPE_UNION:
	    {
		GType type = get_gtype ((GIRegisteredTypeInfo *) container);
		if (!type || type == G_TYPE_NONE) {
			dwarn ("  -> untyped record\n");
			sv = struct_to_sv (container, info_type, pointer, FALSE);
		} else {
			dwarn ("  -> boxed: type=%s (%"G_GSIZE_FORMAT")\n",
			       g_type_name (type), type);
			sv = gperl_new_boxed (pointer, type, FALSE);
		}
		dwarn ("  -> record pointer: %p\n", pointer);
		break;
	    }

	    default:
		ccroak ("Don't know how to handle info type %d for instance pointer", info_type);
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

	dwarn ("interface = %p (%s), type = %d (%s)\n",
	       interface, g_base_info_get_name (interface),
	       info_type, g_info_type_to_string (info_type));

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
			dwarn ("  -> untyped record\n");
			g_assert (!need_value_semantics);
			/* Find out whether this untyped record is a member of
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
		}

		else if (type == G_TYPE_CLOSURE) {
			/* FIXME: User cannot supply user data. */
			dwarn ("  -> closure\n");
			g_assert (!need_value_semantics);
			arg->v_pointer = gperl_closure_new (sv, NULL, FALSE);
		}

		else if (type == G_TYPE_VALUE) {
			GValue *gvalue = SvGValueWrapper (sv);
			dwarn ("  -> value\n");
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
		}

		else if (g_type_is_a (type, G_TYPE_BOXED)) {
			dwarn ("  -> boxed: type=%s, name=%s, caller-allocates=%d, is-pointer=%d\n",
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

#if GLIB_CHECK_VERSION (2, 24, 0)
		else if (g_type_is_a (type, G_TYPE_VARIANT)) {
			dwarn ("  -> variant type\n");
			g_assert (!need_value_semantics);
			arg->v_pointer = SvGVariant (sv);
			if (GI_TRANSFER_EVERYTHING == transfer)
				g_variant_ref (arg->v_pointer);
		}
#endif

		else {
			ccroak ("Cannot convert SV to record value of unknown type %s (%" G_GSIZE_FORMAT ")",
			        g_type_name (type), type);
		}
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    {
		gint value;
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (G_TYPE_NONE == type) {
			ccroak ("Could not handle unknown enum type %s",
			        g_base_info_get_name (interface));
		}
		value = gperl_convert_enum (type, sv);
		_store_enum (interface, value, arg);
		break;
	    }

	    case GI_INFO_TYPE_FLAGS:
	    {
		gint value;
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (G_TYPE_NONE == type) {
			ccroak ("Could not handle unknown flags type %s",
			        g_base_info_get_name (interface));
		}
		value = gperl_convert_flags (type, sv);
		_store_enum (interface, value, arg);
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

	dwarn ("arg %p, info %p\n", arg, info);

	interface = g_type_info_get_interface (info);
	if (!interface)
		ccroak ("Could not convert arg %p to SV", arg);
	info_type = g_base_info_get_type (interface);
	dwarn ("  info type: %d (%s)\n",
	       info_type, g_info_type_to_string (info_type));

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
			dwarn ("  -> untyped record\n");
			sv = struct_to_sv (interface, info_type, arg->v_pointer, own);
		}

		else if (type == G_TYPE_VALUE) {
			dwarn ("  -> value\n");
			sv = gperl_sv_from_value (arg->v_pointer);
			if (own)
				g_boxed_free (type, arg->v_pointer);
		}

		else if (g_type_is_a (type, G_TYPE_BOXED)) {
			dwarn ("  -> boxed: type=%"G_GSIZE_FORMAT" (%s)\n",
			       type, g_type_name (type));
			sv = gperl_new_boxed (arg->v_pointer, type, own);
		}

#if GLIB_CHECK_VERSION (2, 24, 0)
		else if (g_type_is_a (type, G_TYPE_VARIANT)) {
			dwarn ("  -> variant\n");
			sv = own ? newSVGVariant_noinc (arg->v_pointer)
			         : newSVGVariant (arg->v_pointer);
		}
#endif

		else {
			ccroak ("Cannot convert record value of unknown type %s (%" G_GSIZE_FORMAT ") to SV",
			        g_type_name (type), type);
		}
		break;
	    }

	    case GI_INFO_TYPE_ENUM:
	    {
		gint value;
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (G_TYPE_NONE == type) {
			ccroak ("Could not handle unknown enum type %s",
			        g_base_info_get_name (interface));
		}
		value = _retrieve_enum (interface, arg);
		sv = gperl_convert_back_enum (type, value);
		break;
	    }

	    case GI_INFO_TYPE_FLAGS:
	    {
		gint value;
		GType type = get_gtype ((GIRegisteredTypeInfo *) interface);
		if (G_TYPE_NONE == type) {
			ccroak ("Could not handle unknown flags type %s",
			        g_base_info_get_name (interface));
		}
		value = _retrieve_enum (interface, arg);
		sv = gperl_convert_back_flags (type, value);
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

/* ------------------------------------------------------------------------- */

void
_store_enum (GIEnumInfo * info, gint value, GIArgument * arg)
{
	GITypeTag tag = g_enum_info_get_storage_type (info);
	switch (tag) {
	    case GI_TYPE_TAG_BOOLEAN:
		arg->v_boolean = (gboolean) value;
		break;

	    case GI_TYPE_TAG_INT8:
		arg->v_int8 = (gint8) value;
		break;

	    case GI_TYPE_TAG_UINT8:
		arg->v_uint8 = (guint8) value;
		break;

	    case GI_TYPE_TAG_INT16:
		arg->v_int16 = (gint16) value;
		break;

	    case GI_TYPE_TAG_UINT16:
		arg->v_uint16 = (guint16) value;
		break;

	    case GI_TYPE_TAG_INT32:
		arg->v_int32 = (gint32) value;
		break;

	    case GI_TYPE_TAG_UINT32:
		arg->v_uint32 = (guint32) value;
		break;

	    case GI_TYPE_TAG_INT64:
		arg->v_int64 = (gint64) value;
		break;

	    case GI_TYPE_TAG_UINT64:
		arg->v_uint64 = (guint64) value;
		break;

	    default:
		ccroak ("Unhandled enumeration type %s (%d) encountered",
		        g_type_tag_to_string (tag), tag);
	}
}

gint
_retrieve_enum (GIEnumInfo * info, GIArgument * arg)
{
	GITypeTag tag = g_enum_info_get_storage_type (info);
	switch (tag) {
	    case GI_TYPE_TAG_BOOLEAN:
		return (gint) arg->v_boolean;

	    case GI_TYPE_TAG_INT8:
		return (gint) arg->v_int8;

	    case GI_TYPE_TAG_UINT8:
		return (gint) arg->v_uint8;

	    case GI_TYPE_TAG_INT16:
		return (gint) arg->v_int16;

	    case GI_TYPE_TAG_UINT16:
		return (gint) arg->v_uint16;

	    case GI_TYPE_TAG_INT32:
		return (gint) arg->v_int32;

	    case GI_TYPE_TAG_UINT32:
		return (gint) arg->v_uint32;

	    case GI_TYPE_TAG_INT64:
		return (gint) arg->v_int64;

	    case GI_TYPE_TAG_UINT64:
		return (gint) arg->v_uint64;

	    default:
		ccroak ("Unhandled enumeration type %s (%d) encountered",
		        g_type_tag_to_string (tag), tag);
		return 0;
	}
}
