/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

static void
store_fields (HV *fields, GIBaseInfo *info, GIInfoType info_type)
{
	const gchar *namespace;
	AV *av;
	gint i;

	namespace = g_base_info_get_name (info);
	av = newAV ();

	switch (info_type) {
	    case GI_INFO_TYPE_BOXED:
	    case GI_INFO_TYPE_STRUCT:
	    {
		gint n_fields = g_struct_info_get_n_fields (
		                   (GIStructInfo *) info);
		for (i = 0; i < n_fields; i++) {
			GIFieldInfo *field_info;
			const gchar *field_name;
			field_info = g_struct_info_get_field ((GIStructInfo *) info, i);
			field_name = g_base_info_get_name ((GIBaseInfo *) field_info);
			av_push (av, newSVpv (field_name, PL_na));
			g_base_info_unref ((GIBaseInfo *) field_info);
		}
		break;
	    }

	    case GI_INFO_TYPE_UNION:
	    {
                gint n_fields = g_union_info_get_n_fields ((GIUnionInfo *) info);
                for (i = 0; i < n_fields; i++) {
                        GIFieldInfo *field_info;
                        const gchar *field_name;
                        field_info = g_union_info_get_field ((GIUnionInfo *) info, i);
                        field_name = g_base_info_get_name ((GIBaseInfo *) field_info);
                        av_push (av, newSVpv (field_name, PL_na));
                        g_base_info_unref ((GIBaseInfo *) field_info);
                }
                break;
	    }

	    default:
		ccroak ("store_fields: unsupported info type %d", info_type);
	}

	gperl_hv_take_sv (fields, namespace, strlen (namespace),
	                  newRV_noinc ((SV *) av));
}

/* This may call Perl code (via arg_to_sv), so it needs to be wrapped with
 * PUTBACK/SPAGAIN by the caller. */
static SV *
get_field (GIFieldInfo *field_info, gpointer mem, GITransfer transfer)
{
	GITypeInfo *field_type;
	GIBaseInfo *interface_info;
	GIArgument value;
	SV *sv = NULL;

	field_type = g_field_info_get_type (field_info);
	interface_info = g_type_info_get_interface (field_type);

	/* This case is not handled by g_field_info_set_field. */
	if (!g_type_info_is_pointer (field_type) &&
	    g_type_info_get_tag (field_type) == GI_TYPE_TAG_INTERFACE &&
	    g_base_info_get_type (interface_info) == GI_INFO_TYPE_STRUCT)
	{
		gsize offset;
		offset = g_field_info_get_offset (field_info);
		value.v_pointer = mem + offset;
		sv = arg_to_sv (&value,
		                field_type,
		                GI_TRANSFER_NOTHING,
		                NULL);
	} else if (g_field_info_get_field (field_info, mem, &value)) {
		sv = arg_to_sv (&value,
		                field_type,
		                transfer,
		                NULL);
	} else {
		ccroak ("Could not get field '%s'",
		        g_base_info_get_name (field_info));
	}

	if (interface_info)
		g_base_info_unref (interface_info);
	g_base_info_unref ((GIBaseInfo *) field_type);

	return sv;
}

static void
set_field (GIFieldInfo *field_info, gpointer mem, GITransfer transfer, SV *value)
{
	GITypeInfo *field_type;
	GIBaseInfo *interface_info;
	GIArgument arg;

	field_type = g_field_info_get_type (field_info);
	interface_info = g_type_info_get_interface (field_type);

	/* FIXME: No GIArgInfo and no
	 * GPerlI11nInvocationInfo here.  What if the
	 * struct contains an object pointer, or a
	 * callback field?  And is it OK to always
	 * allow undef? */

	/* This case is not handled by g_field_info_set_field. */
	if (!g_type_info_is_pointer (field_type) &&
	    g_type_info_get_tag (field_type) == GI_TYPE_TAG_INTERFACE &&
	    g_base_info_get_type (interface_info) == GI_INFO_TYPE_STRUCT)
	{
		gsize offset;
		gssize size;
		/* Enforce GI_TRANSFER_NOTHING since we will copy into the
		 * memory that has already been allocated inside 'mem' */
		sv_to_arg (value, &arg, NULL, field_type,
		           GI_TRANSFER_NOTHING, TRUE, NULL);
		offset = g_field_info_get_offset (field_info);
		size = g_struct_info_get_size (interface_info);
		g_memmove (mem + offset, arg.v_pointer, size);
	} else {
		sv_to_arg (value, &arg, NULL, field_type,
		           transfer, TRUE, NULL);
		if (!g_field_info_set_field (field_info, mem, &arg))
			ccroak ("Could not set field '%s'",
			        g_base_info_get_name (field_info));
	}

	if (interface_info)
		g_base_info_unref (interface_info);
	g_base_info_unref (field_type);
}
