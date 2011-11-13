/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

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
sv_to_array (GITransfer transfer,
             GITypeInfo *type_info,
             SV *sv,
             GPerlI11nInvocationInfo *iinfo)
{
	AV *av;
	GITransfer item_transfer;
	GITypeInfo *param_info;
	GITypeTag param_tag;
	gint i, length, length_pos;
	GPerlI11nArrayInfo *array_info = NULL;
        GArray *array;
        gboolean is_zero_terminated = FALSE;
        gsize item_size;
	gboolean need_struct_value_semantics;

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

	if (!gperl_sv_is_defined (sv))
		return NULL;

	if (!gperl_sv_is_array_ref (sv))
		ccroak ("need an array ref to convert to GArray");

	av = (AV *) SvRV (sv);

        item_transfer = transfer == GI_TRANSFER_CONTAINER
                      ? GI_TRANSFER_NOTHING
                      : transfer;

	param_info = g_type_info_get_param_type (type_info, 0);
	param_tag = g_type_info_get_tag (param_info);
	dwarn ("  GArray: param_info %p with type tag %d (%s) and transfer %d\n",
	       param_info, param_tag,
	       g_type_tag_to_string (g_type_info_get_tag (param_info)),
	       transfer);

        is_zero_terminated = g_type_info_is_zero_terminated (type_info);
        item_size = size_of_type_info (param_info);
	length = av_len (av) + 1;
        array = g_array_sized_new (is_zero_terminated, FALSE, item_size, length);

	/* Arrays containing non-basic types as non-pointers need to be treated
	 * specially.  Prime example: GValue *values = g_new0 (GValue, n);
	 */
	need_struct_value_semantics =
		/* is a compound type, and... */
		!G_TYPE_TAG_IS_BASIC (param_tag) &&
		/* ... a non-pointer is wanted */
		!g_type_info_is_pointer (param_info);
	for (i = 0; i < length; i++) {
		SV **svp;
		svp = av_fetch (av, i, 0);
		if (svp && gperl_sv_is_defined (*svp)) {
			GIArgument arg;

			dwarn ("    converting SV %p\n", *svp);
			/* FIXME: Is it OK to always allow undef here? */
			sv_to_arg (*svp, &arg, NULL, param_info,
			           item_transfer, TRUE, NULL);

                        if (need_struct_value_semantics) {
				/* Copy from the memory area pointed to by
				 * arg.v_pointer. */
				g_array_insert_vals (array, i, arg.v_pointer, 1);
			} else {
				/* Copy from &arg, i.e. the memory area that is
				 * arg. */
				g_array_insert_val (array, i, arg);
			}
		}
	}

	dwarn ("    -> array %p of size %d\n", array, array->len);

	if (length_pos >= 0) {
		array_info->length = length;
	}

	g_base_info_unref ((GIBaseInfo *) param_info);

	return g_array_free (array, FALSE);
}
