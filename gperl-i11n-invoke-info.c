/* -*- mode: c; indent-tabs-mode: t; c-basic-offset: 8; -*- */

static void
prepare_c_invocation_info (GPerlI11nInvocationInfo *iinfo,
                           GICallableInfo *info,
                           IV items,
                           UV internal_stack_offset)
{
	guint i;

	dwarn ("C invoke: %s\n"
	       "  n_args: %d\n",
	       g_base_info_get_name (info),
	       g_callable_info_get_n_args (info));

	iinfo->interface = info;

	iinfo->is_function = GI_IS_FUNCTION_INFO (info);
	iinfo->is_vfunc = GI_IS_VFUNC_INFO (info);
	iinfo->is_callback = (g_base_info_get_type (info) == GI_INFO_TYPE_CALLBACK);
	dwarn ("  is_function = %d, is_vfunc = %d, is_callback = %d\n",
	       iinfo->is_function, iinfo->is_vfunc, iinfo->is_callback);

	iinfo->stack_offset = internal_stack_offset;

	iinfo->is_constructor = FALSE;
	if (iinfo->is_function) {
		iinfo->is_constructor =
			g_function_info_get_flags (info) & GI_FUNCTION_IS_CONSTRUCTOR;
	}
	if (iinfo->is_constructor) {
		iinfo->stack_offset++;
	}

	iinfo->n_given_args = items - iinfo->stack_offset;

	iinfo->n_invoke_args = iinfo->n_args =
		g_callable_info_get_n_args ((GICallableInfo *) info);

	/* FIXME: can a vfunc not throw? */
	iinfo->throws = FALSE;
	if (iinfo->is_function) {
		iinfo->throws =
			g_function_info_get_flags (info) & GI_FUNCTION_THROWS;
	}
	if (iinfo->throws) {
		iinfo->n_invoke_args++;
	}

	if (iinfo->is_vfunc) {
		iinfo->is_method = TRUE;
	} else if (iinfo->is_callback) {
		iinfo->is_method = FALSE;
	} else {
		iinfo->is_method =
			(g_function_info_get_flags (info) & GI_FUNCTION_IS_METHOD)
			&& !iinfo->is_constructor;
	}
	if (iinfo->is_method) {
		iinfo->n_invoke_args++;
	}

	dwarn ("C invoke: %s\n"
	       "  n_args: %d, n_invoke_args: %d, n_given_args: %d\n"
	       "  is_constructor: %d, is_method: %d\n",
	       is_vfunc ? g_base_info_get_name (info) : g_function_info_get_symbol (info),
	       iinfo->n_args, iinfo->n_invoke_args, iinfo->n_given_args,
	       iinfo->is_constructor, iinfo->is_method);

	iinfo->return_type_info =
		g_callable_info_get_return_type ((GICallableInfo *) info);
	iinfo->has_return_value =
		GI_TYPE_TAG_VOID != g_type_info_get_tag (iinfo->return_type_info);
	iinfo->return_type_ffi = g_type_info_get_ffi_type (iinfo->return_type_info);
	iinfo->return_type_transfer = g_callable_info_get_caller_owns ((GICallableInfo *) info);

	/* allocate enough space for all args in both the out and in lists.
	 * we'll only use as much as we need.  since function argument lists
	 * are typically small, this shouldn't be a big problem. */
	if (iinfo->n_invoke_args) {
		gint n = iinfo->n_invoke_args;
		iinfo->in_args = gperl_alloc_temp (sizeof (GIArgument) * n);
		iinfo->out_args = gperl_alloc_temp (sizeof (GIArgument) * n);
		iinfo->out_arg_infos = gperl_alloc_temp (sizeof (GITypeInfo*) * n);
		iinfo->arg_types = gperl_alloc_temp (sizeof (ffi_type *) * n);
		iinfo->args = gperl_alloc_temp (sizeof (gpointer) * n);
		iinfo->aux_args = gperl_alloc_temp (sizeof (GIArgument) * n);
		iinfo->is_automatic_arg = gperl_alloc_temp (sizeof (gboolean) * n);
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

	/* We need to undo the special handling that GInitiallyUnowned
	 * descendants receive from gobject-introspection: values of this type
	 * are always marked transfer=none, even for constructors. */
	if (iinfo->is_constructor &&
	    g_type_info_get_tag (iinfo->return_type_info) == GI_TYPE_TAG_INTERFACE)
	{
		GIBaseInfo * interface = g_type_info_get_interface (iinfo->return_type_info);
		if (GI_IS_REGISTERED_TYPE_INFO (interface) &&
		    g_type_is_a (g_registered_type_info_get_g_type (interface),
		                 G_TYPE_INITIALLY_UNOWNED))
		{
			iinfo->return_type_transfer = GI_TRANSFER_EVERYTHING;
		}
		g_base_info_unref ((GIBaseInfo *) interface);
	}
}

static void
clear_c_invocation_info (GPerlI11nInvocationInfo *iinfo)
{
	g_slist_free (iinfo->free_after_call);

	/* The actual callback infos might be needed later, so we cannot free
	 * them here. */
	g_slist_free (iinfo->callback_infos);

	g_slist_foreach (iinfo->array_infos, (GFunc) g_free, NULL);
	g_slist_free (iinfo->array_infos);

	g_base_info_unref ((GIBaseInfo *) iinfo->return_type_info);
}

/* -------------------------------------------------------------------------- */

static void
prepare_perl_invocation_info (GPerlI11nInvocationInfo *iinfo,
                              GICallableInfo *info)
{
	/* when invoking Perl code, we currently always use a complete
	 * description of the callable (from a record field or some callback
	 * typedef).  this implies that there is no implicit invocant; it
	 * always appears explicitly in the arg list. */

	dwarn ("Perl invoke: %s\n"
	       "  n_args: %d\n",
	       g_base_info_get_name (info),
	       g_callable_info_get_n_args (info));

	iinfo->interface = info;

	iinfo->is_function = GI_IS_FUNCTION_INFO (info);
	iinfo->is_vfunc = GI_IS_VFUNC_INFO (info);
	iinfo->is_callback = (g_base_info_get_type (info) == GI_INFO_TYPE_CALLBACK);
	dwarn ("  is_function = %d, is_vfunc = %d, is_callback = %d\n",
	       iinfo->is_function, iinfo->is_vfunc, iinfo->is_callback);

	iinfo->n_args = g_callable_info_get_n_args (info);

	/* FIXME: 'throws'? */

	iinfo->return_type_info = g_callable_info_get_return_type (info);
	iinfo->has_return_value =
		GI_TYPE_TAG_VOID != g_type_info_get_tag (iinfo->return_type_info);
	iinfo->return_type_ffi = g_type_info_get_ffi_type (iinfo->return_type_info);
	iinfo->return_type_transfer = g_callable_info_get_caller_owns (info);

	iinfo->dynamic_stack_offset = 0;

	/* If the callback is supposed to return a GInitiallyUnowned object
	 * then we must enforce GI_TRANSFER_EVERYTHING.  Otherwise, if the Perl
	 * code returns a newly created object, FREETMPS would finalize it. */
	if (g_type_info_get_tag (iinfo->return_type_info) == GI_TYPE_TAG_INTERFACE &&
	    iinfo->return_type_transfer == GI_TRANSFER_NOTHING)
	{
		GIBaseInfo *interface = g_type_info_get_interface (iinfo->return_type_info);
		if (GI_IS_REGISTERED_TYPE_INFO (interface) &&
		    g_type_is_a (g_registered_type_info_get_g_type (interface),
		                 G_TYPE_INITIALLY_UNOWNED))
		{
			iinfo->return_type_transfer = GI_TRANSFER_EVERYTHING;
		}
		g_base_info_unref (interface);
	}
}

static void
clear_perl_invocation_info (GPerlI11nInvocationInfo *iinfo)
{
	g_slist_free (iinfo->free_after_call);

	/* The actual callback infos might be needed later, so we cannot free
	 * them here. */
	g_slist_free (iinfo->callback_infos);

	g_base_info_unref ((GIBaseInfo *) iinfo->return_type_info);
}
