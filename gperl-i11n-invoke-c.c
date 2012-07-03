/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

static void
invoke_callable (GICallableInfo *info,
                 gpointer func_pointer,
                 SV **sp, I32 ax, SV **mark, I32 items, /* these correspond to dXSARGS */
                 UV internal_stack_offset)
{
	ffi_cif cif;
	gpointer instance = NULL;
	guint i;
	GPerlI11nInvocationInfo iinfo = {0,};
	guint n_return_values;
	GIArgument return_value;
	GError * local_error = NULL;
	gpointer local_error_address = &local_error;

	PERL_UNUSED_VAR (mark);

	prepare_c_invocation_info (&iinfo, info, items, internal_stack_offset);

	if (iinfo.is_method) {
		instance = instance_sv_to_pointer (info, ST (0 + iinfo.stack_offset));
		iinfo.arg_types[0] = &ffi_type_pointer;
		iinfo.args[0] = &instance;
	}

	for (i = 0 ; i < iinfo.n_args ; i++) {
		GIArgInfo * arg_info;
		GITypeInfo * arg_type;
		GITransfer transfer;
		gboolean may_be_null;
		gint perl_stack_pos, ffi_stack_pos;
		SV *current_sv;

		arg_info = g_callable_info_get_arg ((GICallableInfo *) info, i);
		/* In case of out and in-out args, arg_type is unref'ed after
		 * the function has been invoked */
		arg_type = g_arg_info_get_type (arg_info);
		transfer = g_arg_info_get_ownership_transfer (arg_info);
		may_be_null = g_arg_info_may_be_null (arg_info);
		perl_stack_pos = i
                               + iinfo.method_offset
                               + iinfo.stack_offset
                               + iinfo.dynamic_stack_offset;
		ffi_stack_pos = i
		              + iinfo.method_offset;

		/* FIXME: Is this right?  I'm confused about the relation of
		 * the numbers in g_callable_info_get_arg and
		 * g_arg_info_get_closure and g_arg_info_get_destroy.  We used
		 * to add method_offset, but that stopped being correct at some
		 * point. */
		iinfo.current_pos = i; /* + method_offset; */

		dwarn ("  arg %d, tag: %d (%s), is_pointer: %d, is_automatic: %d\n",
		       i,
		       g_type_info_get_tag (arg_type),
		       g_type_tag_to_string (g_type_info_get_tag (arg_type)),
		       g_type_info_is_pointer (arg_type),
		       iinfo.is_automatic_arg[i]);

		/* FIXME: Generate a proper usage message if the user did not
		 * supply enough arguments. */
		current_sv = perl_stack_pos < items ? ST (perl_stack_pos) : &PL_sv_undef;

		switch (g_arg_info_get_direction (arg_info)) {
		    case GI_DIRECTION_IN:
			if (iinfo.is_automatic_arg[i]) {
				iinfo.dynamic_stack_offset--;
#if GI_CHECK_VERSION (1, 29, 0)
			} else if (g_arg_info_is_skip (arg_info)) {
				iinfo.dynamic_stack_offset--;
#endif
			} else {
				sv_to_arg (current_sv,
				           &iinfo.in_args[i], arg_info, arg_type,
				           transfer, may_be_null, &iinfo);
			}
			iinfo.arg_types[ffi_stack_pos] =
				g_type_info_get_ffi_type (arg_type);
			iinfo.args[ffi_stack_pos] = &iinfo.in_args[i];
			g_base_info_unref ((GIBaseInfo *) arg_type);
			break;

		    case GI_DIRECTION_OUT:
			if (g_arg_info_is_caller_allocates (arg_info)) {
				iinfo.aux_args[i].v_pointer =
					allocate_out_mem (arg_type);
				iinfo.out_args[i].v_pointer = &iinfo.aux_args[i];
				iinfo.args[ffi_stack_pos] = &iinfo.aux_args[i];
			} else {
				iinfo.out_args[i].v_pointer = &iinfo.aux_args[i];
				iinfo.args[ffi_stack_pos] = &iinfo.out_args[i];
			}
			iinfo.out_arg_infos[i] = arg_type;
			iinfo.arg_types[ffi_stack_pos] = &ffi_type_pointer;
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
#if GI_CHECK_VERSION (1, 29, 0)
			} else if (g_arg_info_is_skip (arg_info)) {
				iinfo.dynamic_stack_offset--;
#endif
			} else {
				/* We pass iinfo.in_args[i].v_pointer here,
				 * not &iinfo.in_args[i], so that the value
				 * pointed to is filled from the SV. */
				sv_to_arg (current_sv,
				           iinfo.in_args[i].v_pointer, arg_info, arg_type,
				           transfer, may_be_null, &iinfo);
			}
			iinfo.out_arg_infos[i] = arg_type;
			iinfo.arg_types[ffi_stack_pos] = &ffi_type_pointer;
			iinfo.args[ffi_stack_pos] = &iinfo.in_args[i];
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
		g_base_info_unref ((GIBaseInfo *) arg_info);
	}

	if (iinfo.throws) {
		iinfo.args[iinfo.n_invoke_args - 1] = &local_error_address;
		iinfo.arg_types[iinfo.n_invoke_args - 1] = &ffi_type_pointer;
	}

	/* prepare and call the function */
	if (FFI_OK != ffi_prep_cif (&cif, FFI_DEFAULT_ABI, iinfo.n_invoke_args,
	                            iinfo.return_type_ffi, iinfo.arg_types))
	{
		clear_c_invocation_info (&iinfo);
		ccroak ("Could not prepare a call interface");
	}

	ffi_call (&cif, func_pointer, &return_value, iinfo.args);

	/* free call-scoped callback infos */
	g_slist_foreach (iinfo.free_after_call,
	                 (GFunc) release_perl_callback, NULL);

	if (local_error) {
		gperl_croak_gerror (NULL, local_error);
	}

	/*
	 * handle return values
	 */
	n_return_values = 0;

	/* place return value and output args on the stack */
	if (iinfo.has_return_value
#if GI_CHECK_VERSION (1, 29, 0)
	    && !g_callable_info_skip_return ((GICallableInfo *) info)
#endif
	   )
	{
		SV *value;
		value = SAVED_STACK_SV (arg_to_sv (&return_value,
		                                   iinfo.return_type_info,
		                                   iinfo.return_type_transfer,
		                                   &iinfo));
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
#if GI_CHECK_VERSION (1, 29, 0)
		if (g_arg_info_is_skip (arg_info)) {
			g_base_info_unref ((GIBaseInfo *) arg_info);
			continue;
		}
#endif
		switch (g_arg_info_get_direction (arg_info)) {
		    case GI_DIRECTION_OUT:
		    case GI_DIRECTION_INOUT:
		    {
			GITransfer transfer;
			SV *sv;
			/* If we allocated the memory ourselves, we always own it. */
			transfer = g_arg_info_is_caller_allocates (arg_info)
			         ? GI_TRANSFER_CONTAINER
			         : g_arg_info_get_ownership_transfer (arg_info);
			sv = SAVED_STACK_SV (arg_to_sv (iinfo.out_args[i].v_pointer,
			                                iinfo.out_arg_infos[i],
			                                transfer,
			                                &iinfo));
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

	clear_c_invocation_info (&iinfo);

	dwarn ("  number of return values: %d\n", n_return_values);

	PUTBACK;
}

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
		GPerlI11nPerlCallbackInfo *cinfo = l->data;
		if (pos == cinfo->destroy_pos) {
			dwarn ("  setting automatic arg %d (destroy notify for calllback %p)\n",
			       pos, cinfo);
			/* If the code pointer is NULL, then the user actually
			 * specified undef for the callback or nothing at all,
			 * in which case we must not install our destroy notify
			 * handler. */
			arg->v_pointer = cinfo->code ? release_perl_callback : NULL;
			return;
		}
	}

	ccroak ("Could not handle automatic arg %d", pos);
}

static gpointer
allocate_out_mem (GITypeInfo *arg_type)
{
	GIBaseInfo *interface_info;
	GIInfoType type;

	interface_info = g_type_info_get_interface (arg_type);
	g_assert (interface_info);
	type = g_base_info_get_type (interface_info);
	g_base_info_unref (interface_info);

	switch (type) {
	    case GI_INFO_TYPE_STRUCT:
	    {
		/* No plain g_struct_info_get_size (interface_info) here so
		 * that we get the GValue override. */
		gsize size = size_of_interface (arg_type);
		return g_malloc0 (size);
	    }
	    default:
		g_assert_not_reached ();
		return NULL;
	}
}
