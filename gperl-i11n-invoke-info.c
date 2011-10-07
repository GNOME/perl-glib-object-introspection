static void
prepare_invocation_info (GPerlI11nInvocationInfo *iinfo,
                         GICallableInfo *info,
                         IV items,
                         UV internal_stack_offset)
{
	gboolean is_vfunc;
	guint i;

	is_vfunc = GI_IS_VFUNC_INFO (info);

	iinfo->stack_offset = internal_stack_offset;

	iinfo->is_constructor = is_vfunc
		? FALSE
		: g_function_info_get_flags (info) & GI_FUNCTION_IS_CONSTRUCTOR;
	if (iinfo->is_constructor) {
		iinfo->stack_offset++;
	}

	iinfo->n_given_args = items - iinfo->stack_offset;

	iinfo->n_invoke_args = iinfo->n_args =
		g_callable_info_get_n_args ((GICallableInfo *) info);

	/* FIXME: can a vfunc not throw? */
	iinfo->throws = is_vfunc
		? FALSE
		: g_function_info_get_flags (info) & GI_FUNCTION_THROWS;
	if (iinfo->throws) {
		iinfo->n_invoke_args++;
	}

	if (is_vfunc) {
		iinfo->is_method = TRUE;
	} else {
		iinfo->is_method =
			(g_function_info_get_flags (info) & GI_FUNCTION_IS_METHOD)
			&& !iinfo->is_constructor;
	}
	if (iinfo->is_method) {
		iinfo->n_invoke_args++;
	}

	dwarn ("invoke: %s\n"
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
